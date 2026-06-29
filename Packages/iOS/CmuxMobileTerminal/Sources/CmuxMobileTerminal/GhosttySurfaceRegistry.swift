import CmuxMobileDiagnostics
import CmuxMobileTerminalKit
import GhosttyKit
import UIKit

/// The surface-pointer → view registry and its registry-scoped reads, split
/// out of `GhosttySurfaceView.swift` so the lookup machinery and the "View as
/// Text" capture live in one cohesive file. Everything here is `internal`
/// (not `private`) only so the main class file's lifecycle/snapshot paths can
/// keep using the registry across the file boundary; nothing is exported
/// beyond the module except `copyableTerminalText(surfaceID:)`.
final class WeakGhosttySurfaceViewBox {
    weak var value: GhosttySurfaceView?

    init(_ value: GhosttySurfaceView) {
        self.value = value
    }
}

extension GhosttySurfaceView {
    @MainActor
    static var registeredSurfaceViews: [UInt: WeakGhosttySurfaceViewBox] = [:]

    @MainActor
    static func register(surface: ghostty_surface_t, for view: GhosttySurfaceView) {
        registeredSurfaceViews[surfaceIdentifier(for: surface)] = WeakGhosttySurfaceViewBox(view)
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
    }

    @MainActor
    static func unregister(surface: ghostty_surface_t) {
        registeredSurfaceViews.removeValue(forKey: surfaceIdentifier(for: surface))
    }

    @MainActor
    static func view(for surface: ghostty_surface_t) -> GhosttySurfaceView? {
        let identifier = surfaceIdentifier(for: surface)
        guard let view = registeredSurfaceViews[identifier]?.value else {
            registeredSurfaceViews.removeValue(forKey: identifier)
            return nil
        }
        return view
    }

    static func surfaceIdentifier(for surface: ghostty_surface_t) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(surface))
    }

    /// Full-content capture for the "View as Text" copy sheet: the SCREEN
    /// range (scrollback history plus every written row) of the on-screen
    /// terminal surface, read entirely on the phone's own libghostty surface —
    /// no Mac round-trip, works offline.
    ///
    /// Same threading contract as ``visibleTerminalSnapshot()``: the read runs
    /// on the serial `outputQueue` because `ghostty_surface_read_text` takes
    /// the surface lock that `process_output` holds during a render storm, so
    /// a main-thread read would stall the present and blank the terminal.
    /// Unlike that synchronous DEV path there is no bounded semaphore wait
    /// here — the caller awaits, so a busy queue just resumes the continuation
    /// late while the sheet shows its loading state.
    ///
    /// The continuation body enqueues on `outputQueue` synchronously while
    /// still on the main actor, so the read is FIFO-ordered before any
    /// later-enqueued `disposeSurface` free of the same pointer — the same
    /// lifetime argument `visibleTerminalSnapshot()` relies on.
    ///
    /// The read is bounded at the source: iOS surfaces are created with
    /// `scrollback-limit = 2000000` (see `GhosttyRuntime.applyiOSDefaults`),
    /// so the SCREEN range can never materialize more than ~2MB of text no
    /// matter how long the session ran. The sheet's 5000-line budget is then
    /// applied off-main on top of that hard cap.
    ///
    /// - Parameter surfaceID: The shell-level surface/terminal id the caller
    ///   wants text for (the same id the mounting representable stamped on the
    ///   view as ``hostSurfaceID``). The lookup is scoped to that id so a
    ///   second visible surface — another iPad scene, an in-flight transition —
    ///   can never leak a different workspace's terminal into the capture.
    /// - Returns: The surface's screen text, or nil when that terminal has no
    ///   mounted surface or the read fails.
    public static func copyableTerminalText(surfaceID: String) async -> String? {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        // Scoped pick: only views stamped with the requested id qualify, and
        // only while actually on screen (same visibility filter as
        // `visibleTerminalSnapshot()`). A dismantling view can linger in the
        // registry with a non-nil surface until its queued dispose runs, and
        // its content stops at whenever its byte stream detached — prefer the
        // sheet's honest empty state over silently copying that stale text.
        // If the same terminal is mounted in several scenes the contents are
        // identical, so the lowest-keyed visible match keeps the pick
        // deterministic. The eligibility rule itself lives in
        // `CopyableTerminalTextSelection` so it is host-testable without UIKit;
        // this just maps the live registry onto that pure predicate.
        //
        // The resolve happens on the main actor at the call site (the menu tap),
        // BEFORE the sheet finishes presenting, so the surface is still
        // window-attached and visible when the predicate runs — a sheet
        // presentation that briefly drops the presenter's window/alpha can no
        // longer turn the live surface into a miss.
        let orderedViews = registeredSurfaceViews
            .sorted { $0.key < $1.key }
            .compactMap(\.value.value)
        let candidates = orderedViews.map { view in
            CopyableTerminalTextSelection.Candidate(
                hostSurfaceID: view.hostSurfaceID,
                hasSurface: view.surface != nil,
                hasWindow: view.window != nil,
                isHidden: view.isHidden,
                alpha: Double(view.alpha)
            )
        }
        let chosen = CopyableTerminalTextSelection.chosenIndex(from: candidates, for: surfaceID)
            .map { orderedViews[$0] }

        #if DEBUG
        let candidateSummary = candidates
            .map { "[id=\($0.hostSurfaceID ?? "nil") surf=\($0.hasSurface) win=\($0.hasWindow) hidden=\($0.isHidden) a=\(String(format: "%.2f", $0.alpha))]" }
            .joined(separator: " ")
        MobileDebugLog.anchormux(
            "viewAsText.pick want=\(surfaceID) count=\(candidates.count) chosen=\(chosen == nil ? "none" : "yes") \(candidateSummary)"
        )
        #endif

        guard let surface = chosen?.surface else { return nil }
        let handle = CopyableTextSurfaceHandle(surface: surface)
        return await withCheckedContinuation { continuation in
            outputQueue.async {
                // SCREEN = scrollback + all written rows. `surfaceText` returns a
                // non-nil empty string for a zero-byte range, so a plain `??`
                // never fell back when SCREEN read empty-but-ok. Route both reads
                // through the pure decision so a nil OR empty SCREEN still tries
                // VIEWPORT before the sheet gives up.
                let screen = surfaceText(handle.surface, pointTag: GHOSTTY_POINT_SCREEN)
                let viewport = surfaceText(handle.surface, pointTag: GHOSTTY_POINT_VIEWPORT)
                let text = CopyableTerminalTextSelection.resolvedText(screen: screen, viewport: viewport)
                #if DEBUG
                func describe(_ value: String?) -> String {
                    guard let value else { return "nil" }
                    return value.isEmpty ? "empty" : "\(value.count)chars"
                }
                MobileDebugLog.anchormux(
                    "viewAsText.read screen=\(describe(screen)) viewport=\(describe(viewport)) resolved=\(describe(text))"
                )
                #endif
                continuation.resume(returning: text)
            }
        }
    }
}

/// Carrier for the "View as Text" sheet's surface pointer across the hop to
/// `GhosttySurfaceView.outputQueue`. Same safety argument as
/// `VisibleSnapshotRequest` in `GhosttySurfaceView.swift`: the pointer is only
/// dereferenced on the queue that owns `process_output` and is FIFO-ordered
/// before any queued free — hence `@unchecked Sendable`.
///
/// Deliberately `private` to this file: it holds the class's raw
/// `ghostty_surface_t`, which must not escape `GhosttySurfaceView`'s
/// queue/lifetime discipline into the wider module.
private struct CopyableTextSurfaceHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
}
