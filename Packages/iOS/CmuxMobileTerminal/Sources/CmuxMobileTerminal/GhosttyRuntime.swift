#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
import OSLog
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "ghostty.runtime")

// lint:allow free-function — @convention(c) trampoline: libghostty takes a C
// function pointer, which cannot capture context or live on a Swift type.
private func cmuxIOSRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyRuntime.handleReadClipboard(userdata, location: location, state: state)
}

@MainActor
public final class GhosttyRuntime {
    enum RuntimeError: LocalizedError {
        case backendInitFailed(code: Int32)
        case appCreationFailed

        var errorDescription: String? {
            switch self {
            case .backendInitFailed(let code):
                return String(
                    format: String(
                        localized: "terminal.runtime.init_failed",
                        defaultValue: "libghostty initialization failed (%d)"
                    ),
                    Int(code)
                )
            case .appCreationFailed:
                return String(
                    localized: "terminal.runtime.app_creation_failed",
                    defaultValue: "libghostty app creation failed"
                )
            }
        }
    }

    private static var backendInitialized = false
    private static var sharedResult: Result<GhosttyRuntime, Error>?
    private static var clipboardReader: @MainActor () -> String? = { UIPasteboard.general.string }
    private static var clipboardWriter: @MainActor (String?) -> Void = { UIPasteboard.general.string = $0 }
    private let fileManager: FileManager
    private let iOSConfigRootURL: URL

    func applyTheme(
        _ configTheme: TerminalTheme,
        to surfaceView: GhosttySurfaceView
    ) {
        guard let surface = surfaceView.surface,
              let newConfig = makeThemeConfig(configTheme) else { return }
        let surfaceBits = Int(bitPattern: surface)
        let configBits = Int(bitPattern: newConfig)
        surfaceView.outputQueue.async {
            guard let surface = ghostty_surface_t(bitPattern: surfaceBits),
                  let config = ghostty_config_t(bitPattern: configBits) else { return }
            ghostty_surface_update_theme_config(surface, config)
            ghostty_config_free(config)
        }
    }

    func makeThemeConfig(_ configTheme: TerminalTheme) -> ghostty_config_t? {
        guard let baseConfig = config,
              let newConfig = ghostty_config_clone(baseConfig) else { return nil }
        applyGhosttyiOSTheme(configTheme.validatedOrDefault(), to: newConfig)
        ghostty_config_finalize(newConfig)
        return newConfig
    }

    // libghostty handles are opaque C pointers (typedef `void *`). They
    // aren't Sendable in Swift's type system, but `GhosttyRuntime` is a
    // process-lifetime singleton and the pointer never escapes to a
    // thread that wasn't also coordinated through `@MainActor`. Mark them
    // `nonisolated(unsafe)` so `deinit` (which Swift 6 makes nonisolated)
    // can free them without a synchronous main-actor hop.
    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    nonisolated(unsafe) private(set) var config: ghostty_config_t?

    public static func shared() throws -> GhosttyRuntime {
        if let sharedResult {
            return try sharedResult.get()
        }

        do {
            let runtime = try GhosttyRuntime()
            sharedResult = .success(runtime)
            return runtime
        } catch {
            sharedResult = nil
            throw error
        }
    }

    init(
        fileManager: FileManager = FileManager(),
        iOSConfigRootURL: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.iOSConfigRootURL = iOSConfigRootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        if !Self.backendInitialized {
            let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
            guard result == GHOSTTY_SUCCESS else {
                throw RuntimeError.backendInitFailed(code: result)
            }
            Self.backendInitialized = true
        }

        let config = ghostty_config_new()
        loadGhosttyConfig(config)
        ghostty_config_finalize(config)

        #if DEBUG
        let diagCount = Int(ghostty_config_diagnostics_count(config))
        log.debug("config loaded, \(diagCount, privacy: .public) diagnostics")
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(config, UInt32(i))
            if let msg = diag.message {
                log.debug("diag[\(i, privacy: .public)] = \(String(cString: msg), privacy: .public)")
            }
        }

        // Read back background color to verify config was applied
        var bgColor = ghostty_config_color_s()
        let bgKey = "background"
        let hasBg = ghostty_config_get(config, &bgColor, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8)))
        log.debug("background config get=\(hasBg, privacy: .public) r=\(bgColor.r, privacy: .public) g=\(bgColor.g, privacy: .public) b=\(bgColor.b, privacy: .public)")

        var fontSize: Float64 = 0
        let fontKey = "font-size"
        let hasFont = ghostty_config_get(config, &fontSize, fontKey, UInt(fontKey.lengthOfBytes(using: .utf8)))
        log.debug("font-size config get=\(hasFont, privacy: .public) value=\(fontSize, privacy: .public)")
        #endif

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = { userdata in
            GhosttyRuntime.handleWakeup(userdata)
        }
        runtimeConfig.action_cb = { app, target, action in
            GhosttyRuntime.handleAction(app, target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = cmuxIOSRuntimeReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = { _, _, _, _ in
            // iOS embed doesn't currently support clipboard confirmation prompts.
        }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            GhosttyRuntime.handleWriteClipboard(
                userdata,
                location: location,
                content: content,
                len: len,
                confirm: confirm
            )
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            GhosttyRuntime.handleCloseSurface(userdata, processAlive: processAlive)
        }

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            throw RuntimeError.appCreationFailed
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

    func tick() {
        guard let app else { return }
        MobileDebugLog.anchormux("runtime.tick")
        ghostty_app_tick(app)
    }

    nonisolated static func iOSConfigURLs(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) -> [URL] {
        #if os(iOS)
        var urls: [URL] = []
        if let overridePath = processInfo.environment["CMUX_GHOSTTY_CONFIG_PATH"], !overridePath.isEmpty {
            let overrideURL = URL(fileURLWithPath: overridePath)
            if isReadableConfigFile(at: overrideURL, fileManager: fileManager) {
                urls.append(overrideURL)
            }
        }

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let fallbackURLs = [
                appSupport.appendingPathComponent("ghostty/config.ghostty", isDirectory: false),
                appSupport.appendingPathComponent("ghostty/config", isDirectory: false),
            ]
            for url in fallbackURLs where isReadableConfigFile(at: url, fileManager: fileManager) {
                urls.append(url)
            }
        }
        return urls
        #else
        return []
        #endif
    }

    private nonisolated static func isReadableConfigFile(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }

    nonisolated private static func handleWakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        Task { @MainActor in
            runtime.tick()
        }
    }

    nonisolated private static func handleAction(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            let payload = action.action.open_url
            guard let urlPtr = payload.url else { return false }
            let data = Data(bytes: urlPtr, count: Int(payload.len))
            guard let urlString = String(data: data, encoding: .utf8),
                  let url = URL(string: urlString) else { return false }

            Task { @MainActor in
                UIApplication.shared.open(url)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface else { return false }
            Task { @MainActor in
                GhosttySurfaceView.focusInput(for: surface)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_SET_TITLE {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let titlePtr = action.action.set_title.title else { return false }
            let title = String(cString: titlePtr)
            Task { @MainActor in
                GhosttySurfaceView.setTitle(title, for: surface)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface else { return false }
            Task { @MainActor in
                let title = GhosttySurfaceView.title(for: surface)
                clipboardWriter(title)
            }
            return true
        }

        if action.tag == GHOSTTY_ACTION_RING_BELL {
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface else { return false }
            Task { @MainActor in
                GhosttySurfaceView.ringBell(for: surface)
            }
            return true
        }

        #if DEBUG
        if action.tag == GHOSTTY_ACTION_SCROLLBAR {
            let sb = action.action.scrollbar
            MobileDebugLog.anchormux("scroll.bar total=\(sb.total) offset=\(sb.offset) len=\(sb.len)")
            if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
                Task { @MainActor in
                    GhosttySurfaceView.view(for: surface)?.recordBottomScrollStressScrollbar(total: Int(sb.total), offset: Int(sb.offset), len: Int(sb.len))
                }
            }
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
        // The libghostty userdata + state pointers are opaque tokens
        // (no Swift Sendable conformance). Cross the actor boundary as
        // Int bit-patterns to keep the strict-concurrency checker happy
        // and rebuild the pointers on the main actor side. The pointers
        // outlive this scope because libghostty owns their lifetime.
        let userdataBits: Int = userdata.map { Int(bitPattern: $0) } ?? 0
        let stateBits: Int = state.map { Int(bitPattern: $0) } ?? 0
        Task { @MainActor in
            let userdataPtr = userdataBits == 0
                ? nil
                : UnsafeMutableRawPointer(bitPattern: userdataBits)
            let statePtr = stateBits == 0
                ? nil
                : UnsafeMutableRawPointer(bitPattern: stateBits)
            guard let surfaceView = surfaceView(from: userdataPtr),
                  let surface = surfaceView.surface else { return }
            let value = clipboardReader() ?? ""

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, statePtr, false)
            }
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

        for index in 0..<len {
            let item = content[index]
            guard let mimePtr = item.mime,
                  let dataPtr = item.data else { continue }
            let mime = String(cString: mimePtr)
            guard mime == "text/plain" else { continue }
            let value = String(cString: dataPtr)
            Task { @MainActor in
                clipboardWriter(value)
            }
            return
        }
    }

    nonisolated private static func handleCloseSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        GhosttySurfaceBridge.fromOpaque(userdata)?.handleCloseSurface(processAlive: processAlive)
    }

    nonisolated private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        GhosttySurfaceBridge.fromOpaque(userdata)?.surfaceView
    }

    @MainActor
    static func simulateSurfaceActionForTesting(
        surface: ghostty_surface_t,
        tag: ghostty_action_tag_e
    ) -> Bool {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = surface

        var action = ghostty_action_s()
        action.tag = tag
        return handleAction(nil, target: target, action: action)
    }

    @MainActor
    static func simulateSurfaceSetTitleActionForTesting(
        surface: ghostty_surface_t,
        title: String
    ) -> Bool {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = surface

        var handled = false
        title.withCString { titlePtr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title = ghostty_action_set_title_s(title: titlePtr)
            handled = handleAction(nil, target: target, action: action)
        }
        return handled
    }

    @MainActor
    static func setClipboardHandlersForTesting(
        reader: @escaping @Sendable () -> String?,
        writer: @escaping @Sendable (String?) -> Void
    ) {
        clipboardReader = reader
        clipboardWriter = writer
    }

    @MainActor
    static func resetClipboardHandlersForTesting() {
        clipboardReader = { UIPasteboard.general.string }
        clipboardWriter = { UIPasteboard.general.string = $0 }
    }
}

private extension GhosttyRuntime {
    func loadGhosttyConfig(
        _ config: ghostty_config_t?,
        theme: TerminalTheme = .monokai
    ) {
        guard let config else { return }
        #if os(iOS)
        setupGhosttyiOSConfigEnvironment()
        ensureDefaultGhosttyiOSConfig(theme: theme)
        ghostty_config_load_default_files(config)
        applyGhosttyiOSDefaults(config, theme: theme)
        #else
        ghostty_config_load_default_files(config)
        #endif
    }

    func setupGhosttyiOSConfigEnvironment() {
        setenv("XDG_CONFIG_HOME", iOSConfigRootURL.path, 0)
        if let env = getenv("XDG_CONFIG_HOME") {
            log.debug("XDG_CONFIG_HOME=\(String(cString: env), privacy: .public)")
        }
    }

    func applyGhosttyiOSDefaults(_ config: ghostty_config_t, theme: TerminalTheme) {
        // The phone scrolls the authoritative Mac surface. Local scrollback exists
        // only for bounded local text reads, so cap it below Ghostty's 10MB default.
        let defaults = """
        scrollback-limit = 2000000
        font-family = Menlo
        font-size = 10
        window-padding-balance = false
        window-padding-y = 0
        cursor-style = bar
        cursor-style-blink = true
        \(theme.ghosttyColorDirectives)
        """
        loadInlineGhosttyiOSConfig(defaults, path: "/__cmux_ios__/defaults.conf", into: config)

        var background = ghostty_config_color_s()
        let key = "background"
        let found = ghostty_config_get(config, &background, key, UInt(key.lengthOfBytes(using: .utf8)))
        log.debug("applyiOSDefaults: bg get=\(found, privacy: .public) r=\(background.r, privacy: .public) g=\(background.g, privacy: .public) b=\(background.b, privacy: .public)")
    }

    func applyGhosttyiOSTheme(_ theme: TerminalTheme, to config: ghostty_config_t) {
        // Each surface mirrors the Mac theme. Clear optional colors inherited
        // from the phone config before applying the remote values.
        let directives = """
        bold-color =
        cursor-text =
        \(theme.ghosttyColorDirectives)
        """
        loadInlineGhosttyiOSConfig(
            directives,
            path: "/__cmux_ios__/theme.conf",
            into: config
        )
    }

    func loadInlineGhosttyiOSConfig(
        _ contents: String,
        path syntheticPath: String,
        into config: ghostty_config_t
    ) {
        contents.withCString { contentsPointer in
            syntheticPath.withCString { path in
                ghostty_config_load_string(
                    config,
                    contentsPointer,
                    UInt(contents.lengthOfBytes(using: .utf8)),
                    path
                )
            }
        }
    }

    func ensureDefaultGhosttyiOSConfig(theme: TerminalTheme) {
        let configDirectory = iOSConfigRootURL.appendingPathComponent("ghostty", isDirectory: true)
        let configFile = configDirectory.appendingPathComponent("config", isDirectory: false)
        guard !fileManager.fileExists(atPath: configFile.path) else { return }

        let defaultConfig = """
        font-family = Menlo
        font-size = 10
        window-padding-balance = false
        window-padding-y = 0
        cursor-style = bar
        cursor-style-blink = true
        \(theme.ghosttyColorDirectives)
        """

        do {
            try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try defaultConfig.write(to: configFile, atomically: true, encoding: .utf8)
        } catch {
            log.error("ensureDefaultiOSConfig: failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Optional where Wrapped == String {
    func withCString<T>(_ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
        if let value = self {
            return try value.withCString(body)
        }
        return try body(nil)
    }
}

extension Notification.Name {
    static let ghosttySurfaceDidRequestClose = Notification.Name("ghosttySurfaceDidRequestClose")
    static let ghosttySurfaceDidRingBell = Notification.Name("ghosttySurfaceDidRingBell")
}

#endif
