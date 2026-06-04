#if canImport(UIKit)
internal import GhosttyKit
import CmuxMobileDiagnostics
import Foundation
import OSLog
public import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.engine")

// lint:allow free-function — @convention(c) trampoline: libghostty takes a C
// function pointer, which cannot capture context or live on a Swift type.
private func cmuxIOSEngineReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyEngineService.handleReadClipboard(userdata, location: location, state: state)
}

/// Owns the libghostty backend for the process: `ghostty_init`, the app
/// handle, config loading, and every runtime C callback. Replaces the former
/// `GhosttyRuntime.shared()` singleton — construct one at the app composition
/// root and inject it wherever a surface is created.
///
/// `@MainActor` rather than a free-standing actor on purpose: on iOS the
/// embedder drains libghostty's app mailbox with `ghostty_app_tick` on the
/// main thread, and every app-level action lands in UIKit. Isolating the app
/// handle anywhere else would change the tick executor — the exact class of
/// change the 0x8BADF00D history in the surface view warns about. Blocking
/// per-surface work never runs here; it lives on each
/// ``GhosttySurfaceSession``'s dedicated executor.
@MainActor
public final class GhosttyEngineService {
    /// Everything a host needs for one created surface.
    public struct SurfaceCreation {
        /// The session owning the surface's blocking operations.
        public let session: GhosttySurfaceSession
        /// The surface's ordered host-event stream (single consumer).
        public let events: AsyncStream<GhosttySurfaceHostEvent>
        /// The surface's identity for registry queries and unregistration.
        public let identity: UInt
    }

    /// Process-global `ghostty_init` guard. libghostty must be initialized
    /// exactly once per process; this records that C-library fact, not
    /// shared Swift runtime state, so it stays a static.
    private static var backendInitialized = false

    // libghostty handles are opaque C pointers (typedef `void *`). They are
    // not Sendable in Swift's type system, but every coordinated use goes
    // through `@MainActor`; `nonisolated(unsafe)` lets `deinit` (nonisolated
    // in Swift 6) free them without a synchronous main-actor hop.
    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    nonisolated(unsafe) private var config: ghostty_config_t?

    /// The surface registry this engine routes app-level actions through.
    public let registry: GhosttySurfaceRegistry
    private let clipboard: GhosttyEngineClipboard

    /// Initializes libghostty (once per process), loads config, and creates
    /// the app handle.
    ///
    /// - Parameters:
    ///   - registry: The surface registry actions route through. Construct
    ///     one at the composition root and share it with snapshot consumers.
    ///   - clipboard: The system-clipboard seam (defaults to
    ///     `UIPasteboard.general`).
    /// - Throws: ``GhosttyEngineError`` when backend init or app creation
    ///   fails.
    public init(
        registry: GhosttySurfaceRegistry,
        clipboard: GhosttyEngineClipboard = .uiPasteboard
    ) throws {
        self.registry = registry
        self.clipboard = clipboard
        try Self.initializeBackendIfNeeded()

        guard let config = ghostty_config_new() else {
            throw GhosttyEngineError.appCreationFailed
        }
        Self.loadConfig(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userdata in
            GhosttyEngineService.handleWakeup(userdata)
        }
        runtimeConfig.action_cb = { app, target, action in
            GhosttyEngineService.handleAction(app, target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = cmuxIOSEngineReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in
            // iOS embed doesn't currently support clipboard confirmation prompts.
        }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            GhosttyEngineService.handleWriteClipboard(
                userdata,
                location: location,
                content: content,
                len: len,
                confirm: confirm
            )
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            GhosttySurfaceCallbackBridge.fromOpaque(userdata)?
                .handleCloseSurface(processAlive: processAlive)
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw GhosttyEngineError.appCreationFailed
        }

        self.config = config
        self.app = app
    }

    deinit {
        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
        }
    }

    // MARK: - Surfaces

    /// Creates a libghostty surface hosted by `hostView` (whose layer must be
    /// the Metal render target) and wraps it in a ``GhosttySurfaceSession``.
    ///
    /// Also registers the surface with the engine's ``registry`` so app-level
    /// actions (title, bell, keyboard focus) route to the returned event
    /// stream. The caller must consume `events` from a single main-actor task
    /// and call ``GhosttySurfaceSession/shutdown()`` plus
    /// `registry.unregister(identity:)` when the host goes away.
    ///
    /// - Parameters:
    ///   - hostView: The view backing the surface's Metal layer.
    ///   - fontSize: Initial font size in points.
    ///   - scale: Display scale factor.
    /// - Returns: The created surface bundle, or `nil` when libghostty
    ///   refuses to create a surface.
    public func makeSurfaceSession(
        hostView: UIView,
        fontSize: Float,
        scale: Double
    ) -> SurfaceCreation? {
        guard let app else { return nil }
        let (events, continuation) = AsyncStream.makeStream(of: GhosttySurfaceHostEvent.self)
        let bridge = GhosttySurfaceCallbackBridge(events: continuation, clipboard: clipboard)
        let bridgePointer = Unmanaged.passUnretained(bridge).toOpaque()

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = bridgePointer
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_IOS
        surfaceConfig.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(uiview: Unmanaged.passUnretained(hostView).toOpaque())
        )
        surfaceConfig.scale_factor = scale
        surfaceConfig.font_size = fontSize
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
        surfaceConfig.io_write_cb = { userdata, buffer, length in
            guard let userdata, let buffer, length > 0 else { return }
            let bytes = Data(bytes: buffer, count: Int(length))
            GhosttySurfaceCallbackBridge.fromOpaque(userdata)?.handleWrite(bytes)
        }
        surfaceConfig.io_write_userdata = bridgePointer

        guard let surface = ghostty_surface_new(app, &surfaceConfig) else {
            continuation.finish()
            return nil
        }
        let identity = UInt(bitPattern: UnsafeRawPointer(surface))
        bridge.stampSurfaceIdentity(identity)
        let backend = GhosttyKitSurfaceBackend(surface: surface, bridge: bridge)
        let session = GhosttySurfaceSession(backend: backend, events: continuation)
        bridge.stampSession(session)
        registry.register(identity: identity, session: session, events: continuation)
        return SurfaceCreation(session: session, events: events, identity: identity)
    }

    // MARK: - App lifecycle

    /// Drains the libghostty app mailbox. Main-thread on iOS by design.
    public func tick() {
        guard let app else { return }
        MobileDebugLog.anchormux("runtime.tick")
        ghostty_app_tick(app)
    }

    /// Reads an RGB color key (e.g. `background`, `cursor-color`) from the
    /// loaded config, or `nil` when unset.
    public func configColor(forKey key: String) -> GhosttyConfigColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return nil
        }
        return GhosttyConfigColor(red: color.r, green: color.g, blue: color.b)
    }

    // MARK: - Backend bootstrap (ported verbatim from GhosttyRuntime)

    // Explicitly @MainActor (not just inferred from the enclosing class) so
    // the once-per-process `backendInitialized` guard keeps its isolation even
    // if a future change marks parts of this type nonisolated.
    @MainActor
    private static func initializeBackendIfNeeded() throws {
        guard !backendInitialized else { return }
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            throw GhosttyEngineError.backendInitFailed(code: result)
        }
        backendInitialized = true
    }

    private static func loadConfig(_ config: ghostty_config_t?) {
        guard let config else { return }
        setupiOSConfigEnvironment()
        ensureDefaultiOSConfig()
        ghostty_config_load_default_files(config)
        applyiOSDefaults(config)
    }

    private static func setupiOSConfigEnvironment() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        setenv("XDG_CONFIG_HOME", appSupport.path, 0)
        if let env = getenv("XDG_CONFIG_HOME") {
            log.debug("XDG_CONFIG_HOME=\(String(cString: env), privacy: .public)")
        }
    }

    private static let monokaiDefaultConfig = """
    font-family = Menlo
    font-size = 10
    window-padding-balance = false
    window-padding-y = 0
    cursor-style = bar
    cursor-style-blink = true
    background = #272822
    foreground = #fdfff1
    cursor-color = #c0c1b5
    selection-background = #57584f
    selection-foreground = #fdfff1
    palette = 0=#272822
    palette = 1=#f92672
    palette = 2=#a6e22e
    palette = 3=#e6db74
    palette = 4=#fd971f
    palette = 5=#ae81ff
    palette = 6=#66d9ef
    palette = 7=#fdfff1
    palette = 8=#6e7066
    palette = 9=#f92672
    palette = 10=#a6e22e
    palette = 11=#e6db74
    palette = 12=#fd971f
    palette = 13=#ae81ff
    palette = 14=#66d9ef
    palette = 15=#fdfff1
    """

    private static func applyiOSDefaults(_ config: ghostty_config_t) {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-ios-config-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try monokaiDefaultConfig.write(to: tmpFile, atomically: true, encoding: .utf8)
            tmpFile.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            try FileManager.default.removeItem(at: tmpFile)
        } catch {
            log.error("applyiOSDefaults: failed to write config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func ensureDefaultiOSConfig() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let configDir = appSupport.appendingPathComponent("ghostty", isDirectory: true)
        let configFile = configDir.appendingPathComponent("config", isDirectory: false)
        guard !FileManager.default.fileExists(atPath: configFile.path) else { return }
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try monokaiDefaultConfig.write(to: configFile, atomically: true, encoding: .utf8)
        } catch {
            log.error("ensureDefaultiOSConfig: failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Runtime C callbacks

    nonisolated private static func handleWakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let engine = Unmanaged<GhosttyEngineService>.fromOpaque(userdata).takeUnretainedValue()
        Task { @MainActor in
            engine.tick()
        }
    }

    nonisolated private static func engine(forApp app: ghostty_app_t?) -> GhosttyEngineService? {
        guard let app, let userdata = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyEngineService>.fromOpaque(userdata).takeUnretainedValue()
    }

    nonisolated private static func handleAction(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            let payload = action.action.open_url
            guard let urlPointer = payload.url else { return false }
            let data = Data(bytes: urlPointer, count: Int(payload.len))
            guard let urlString = String(data: data, encoding: .utf8),
                  let url = URL(string: urlString) else { return false }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let engine = engine(forApp: app) else { return false }
            let identity = UInt(bitPattern: UnsafeRawPointer(surface))
            Task { @MainActor in
                engine.registry.dispatchFocusInput(identity: identity)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_SET_TITLE {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let titlePointer = action.action.set_title.title,
                  let engine = engine(forApp: app) else { return false }
            let identity = UInt(bitPattern: UnsafeRawPointer(surface))
            let title = String(cString: titlePointer)
            Task { @MainActor in
                engine.registry.dispatchTitleChanged(identity: identity, title: title)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let engine = engine(forApp: app) else { return false }
            let identity = UInt(bitPattern: UnsafeRawPointer(surface))
            Task { @MainActor in
                let title = engine.registry.title(identity: identity)
                engine.clipboard.write(title)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_RING_BELL {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let engine = engine(forApp: app) else { return false }
            let identity = UInt(bitPattern: UnsafeRawPointer(surface))
            Task { @MainActor in
                engine.registry.dispatchBell(identity: identity)
            }
            return true
        }

        #if DEBUG
        // TEMP bug-2 (scrollback) diagnostic probe carried over from
        // GhosttyRuntime. `total` = scrollback rows available, `offset` =
        // viewport position from the top, `len` = visible rows.
        if action.tag == GHOSTTY_ACTION_SCROLLBAR {
            let scrollbar = action.action.scrollbar
            MobileDebugLog.anchormux("scroll.bar total=\(scrollbar.total) offset=\(scrollbar.offset) len=\(scrollbar.len)")
            return true
        }
        #endif

        return false
    }

    nonisolated fileprivate static func handleReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        // Resolve the bridge synchronously while libghostty still guarantees
        // the surface (and therefore the retained bridge) is alive; the strong
        // Swift reference then keeps the bridge valid across the main-actor
        // hop. The completion itself is submitted as an ordered session
        // command, so it serializes before the surface free and is dropped if
        // the session already shut down — no use-after-free window. The state
        // pointer crosses as an `Int` bit-pattern (opaque token libghostty
        // owns).
        guard let bridge = GhosttySurfaceCallbackBridge.fromOpaque(userdata) else { return false }
        let stateBits: Int = state.map { Int(bitPattern: $0) } ?? 0
        Task { @MainActor in
            guard let session = bridge.session else { return }
            let value = bridge.clipboard.read() ?? ""
            session.submit(.completeClipboardRequest(text: value, stateBits: stateBits))
        }
        return true
    }

    nonisolated private static func handleWriteClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        // Strong bridge reference resolved synchronously (see
        // handleReadClipboard) so the deferred write can never dangle.
        guard let bridge = GhosttySurfaceCallbackBridge.fromOpaque(userdata) else { return }
        for index in 0..<len {
            let item = content[index]
            guard let mimePointer = item.mime,
                  let dataPointer = item.data else { continue }
            let mime = String(cString: mimePointer)
            guard mime == "text/plain" else { continue }
            let value = String(cString: dataPointer)
            Task { @MainActor in
                bridge.clipboard.write(value)
            }
            return
        }
    }
}
#endif
