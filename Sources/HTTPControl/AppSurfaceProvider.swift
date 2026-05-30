import AppKit
import CmuxTerminalAccess
import Foundation

/// Bridges ``SurfaceProvider`` from ``CmuxTerminalAccess`` onto the live
/// ``TerminalController`` surface registry.
///
/// Per Errata E1/D1 every required method is `async throws`; the
/// synchronous ``pendingInputCapacityRemaining(surface:)`` exposes a
/// fast in-memory counter (no actor hop needed on the hot write path).
///
/// IMPORTANT (D9 / spec §5.2): the HTTP control bearer token is
/// **never** exported into spawned PTY child environments. The token
/// lives in `<supportDirectory>/http-control-token` (mode 0600) and is
/// read **only** by the HTTP listener; do **not** add any code path
/// here (or in ``TerminalController``'s env-build sites) that copies
/// the token, or any value derived from ``HTTPControlSettings``, into
/// the env dict passed to fork/exec. Task 0.25 adds a behavioral test
/// that fails if this invariant is violated.
///
/// Per Errata E5 this bridge is a process-wide singleton. The live
/// ``TerminalController`` is injected via ``setController(_:)`` from
/// ``AppDelegate`` at launch; the HTTP listener consumes
/// ``AppSurfaceProvider/shared`` after that.
///
/// Tests that need a synthetic surface without an `AppDelegate` boot
/// the bridge through ``testInject(panel:handle:)`` / ``testReset()``
/// (`#if DEBUG` only).
public final class AppSurfaceProvider: SurfaceProvider, @unchecked Sendable {
    /// Process-wide instance. ``AppDelegate`` calls
    /// ``setController(_:)`` on this instance during launch; the HTTP
    /// server consumes it after that.
    public static let shared = AppSurfaceProvider()

    private let lock = NSLock()
    private var controller: TerminalController?
    #if DEBUG
    private var injected: [SurfaceHandle: SurfaceInfo] = [:]
    #endif

    /// Internal initializer — call ``shared``, not this.
    internal init() {}

    /// Bind the live ``TerminalController``. ``AppDelegate`` calls this
    /// once at launch, before any HTTP request can arrive. Idempotent
    /// when called with the same instance (Phase 1's lazy fallback in
    /// ``TerminalController.terminalAccessService`` relies on this).
    ///
    /// Access is `internal` because ``TerminalController`` is internal to
    /// the app target — `public` on a method that takes an internal type
    /// is rejected at compile time.
    internal func setController(_ controller: TerminalController) {
        lock.lock(); defer { lock.unlock() }
        self.controller = controller
    }

    #if DEBUG
    /// Inject a synthetic ``SurfaceInfo`` keyed by ``SurfaceHandle``.
    ///
    /// Phase 1 test environments (`HTTPControlTestEnv.startWithLiveSurface(...)`)
    /// call this to wire a panel without an `AppDelegate` instance.
    /// The `panel` parameter is intentionally `Any` here so the
    /// fixture can pass a `TerminalPanel` (or a stand-in for the
    /// headless paths) without the bridge having to know about the
    /// AppKit/Panel hierarchy; the bridge only stores the
    /// ``SurfaceInfo`` snapshot it derives from the handle.
    public func testInject(panel: Any, handle: SurfaceHandle) {
        lock.lock(); defer { lock.unlock() }
        let info = SurfaceInfo(
            handle: handle,
            uuid: UUID(),
            workspaceRef: "test:1",
            title: nil,
            cols: 80,
            rows: 24,
            altScreen: false,
            focused: true,
            semanticAvailable: false
        )
        injected[handle] = info
    }

    /// Clear all injected state. Tests call this in `deinit` / teardown.
    public func testReset() {
        lock.lock(); defer { lock.unlock() }
        injected.removeAll()
    }
    #endif

    // MARK: - SurfaceProvider conformance

    public func listSurfaces() async throws -> [SurfaceInfo] {
        #if DEBUG
        let snapshot = lock.withLock { Array(injected.values) }
        if !snapshot.isEmpty { return snapshot }
        #endif
        guard let controller = currentController() else { return [] }
        return await MainActor.run { controller.v2EnumerateSurfaceInfos() }
    }

    public func resolve(_ handle: SurfaceHandle) async throws -> SurfaceInfo? {
        #if DEBUG
        if let info = lock.withLock({ injected[handle] }) { return info }
        #endif
        guard let controller = currentController() else { return nil }
        return await MainActor.run { controller.v2Resolve(handle: handle) }
    }

    public func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String {
        // E10/E19 — derive from readCells via cellsToText. Real impl lands
        // in Phase 1's final task (ScreenRegionReader retirement). Until
        // then, this method calls the controller's existing SCREEN+SURFACE+
        // ACTIVE merge so Phase 0 sockets keep working.
        guard let controller = currentController() else {
            throw TerminalAccessError.unknownSurface
        }
        return try await controller.readSurfaceText(uuid: surface.uuid, region: region)
    }

    public func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
        // Phase 1 wires this to ghostty patch #1's `GhosttyCellsBridge`.
        // Phase 0 stub: E20 — ``readCells`` is a REQUIRED protocol
        // member; conformers that can't satisfy it must throw
        // ``unsupported``, never silently inherit a default.
        throw TerminalAccessError.unsupported(reason: "format=cells requires ghostty patch #1")
    }

    public func writeText(surface: SurfaceInfo, bytes: Data) async throws {
        guard let controller = currentController() else {
            throw TerminalAccessError.unknownSurface
        }
        try await controller.writeSurfaceText(uuid: surface.uuid, bytes: bytes)
    }

    public func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {
        guard let controller = currentController() else {
            throw TerminalAccessError.unknownSurface
        }
        try await controller.writeSurfaceKey(uuid: surface.uuid, event: event)
    }

    public func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {
        // D16 — implementation in ``TerminalController`` must call
        // `ghostty_surface_mouse_button` / `_pos` / `_scroll` directly.
        // Never synthesize `NSEvent` on this path (hits hit-test
        // latency in the unrelated portal layer).
        guard let controller = currentController() else {
            throw TerminalAccessError.unknownSurface
        }
        try await controller.writeSurfaceMouse(uuid: surface.uuid, event: event)
    }

    public func setFocus(surface: SurfaceInfo, gained: Bool) async throws {
        // Socket-focus policy — only `ghostty_surface_set_focus` is
        // invoked; macOS app focus is NOT mutated.
        guard let controller = currentController() else {
            throw TerminalAccessError.unknownSurface
        }
        try await controller.setSurfaceFocus(uuid: surface.uuid, gained: gained)
    }

    public func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int {
        currentController()?.pendingInputCapacityRemaining(uuid: surface.uuid) ?? 0
    }

    // MARK: - Helpers

    private func currentController() -> TerminalController? {
        lock.lock(); defer { lock.unlock() }
        return controller
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
