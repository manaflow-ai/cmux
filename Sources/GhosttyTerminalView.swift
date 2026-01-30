import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Darwin

private enum GhosttyPasteboardHelper {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let value = pasteboard.string(forType: .string) {
            return value
        }

        return pasteboard.string(forType: utf8PlainTextType)
    }

    static func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        return (stringContents(from: pasteboard) ?? "").isEmpty == false
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func escapeForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["GHOSTTYTABS_DEBUG_BG"] == "1" {
            return true
        }
        if UserDefaults.standard.bool(forKey: "cmuxDebugBG") {
            return true
        }
        return UserDefaults.standard.bool(forKey: "GhosttyTabsDebugBG")
    }()
    private let backgroundLogURL = URL(fileURLWithPath: "/tmp/cmux-bg.log")
    private var appObservers: [NSObjectProtocol] = []
    private var displayLink: CVDisplayLink?
    private var displayLinkUsers = 0
    private let displayLinkLock = NSLock()

    private init() {
        initializeGhostty()
    }

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(0, nil)
        if result != GHOSTTY_SUCCESS {
            print("Failed to initialize ghostty: \(result)")
            return
        }

        // Load config
        config = ghostty_config_new()
        guard let config = config else {
            print("Failed to create ghostty config")
            return
        }

        // Load default config
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        updateDefaultBackground(from: config)

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            // Read clipboard
            guard let userdata else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.terminalSurface?.surface else { return }

            let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location)
            let value = pasteboard.flatMap { GhosttyPasteboardHelper.stringContents(from: $0) } ?? ""

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let userdata, let content else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.terminalSurface?.surface else { return }

            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            // Write clipboard
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))

            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboardHelper.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyPasteboardHelper.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return
            }

            DispatchQueue.main.async {
                if let surface = surfaceView.terminalSurface,
                   surface.needsConfirmClose() {
                    AppDelegate.shared?.tabManager?.closePanelWithConfirmation(
                        tabId: tabId,
                        surfaceId: surfaceId
                    )
                    return
                }
                _ = AppDelegate.shared?.tabManager?.closeSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        // Create app
        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            print("Failed to create ghostty app")
            return
        }

        #if os(macOS)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
        #endif
    }

    func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
        AppDelegate.shared?.tabManager?.tickRender()
    }

    func retainDisplayLink() {
        displayLinkLock.lock()
        defer { displayLinkLock.unlock() }
        displayLinkUsers += 1
        if displayLinkUsers == 1 {
            startDisplayLink()
        }
    }

    func releaseDisplayLink() {
        displayLinkLock.lock()
        defer { displayLinkLock.unlock() }
        displayLinkUsers = max(0, displayLinkUsers - 1)
        if displayLinkUsers == 0 {
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        if displayLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let newLink = link else { return }
            displayLink = newLink
            let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, _ -> CVReturn in
                DispatchQueue.main.async {
                    GhosttyApp.shared.tick()
                }
                return kCVReturnSuccess
            }
            CVDisplayLinkSetOutputCallback(newLink, callback, nil)
        }
        if let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
    }

    private func stopDisplayLink() {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    private func updateDefaultBackground(from config: ghostty_config_t?) {
        guard let config else { return }

        var color = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &color, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            defaultBackgroundColor = NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }

        var opacity: Double = 1.0
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        defaultBackgroundOpacity = opacity
        if backgroundLogEnabled {
            logBackground("default background updated color=\(defaultBackgroundColor) opacity=\(String(format: "%.3f", defaultBackgroundOpacity))")
        }
    }

    private func performOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitTree<TerminalSurface>.NewDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> SplitTree<TerminalSurface>.FocusDirection? {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: return .next
        case GHOSTTY_GOTO_SPLIT_UP: return .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: return .spatial(.down)
        case GHOSTTY_GOTO_SPLIT_LEFT: return .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .spatial(.right)
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> SplitTree<TerminalSurface>.Spatial.Direction? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
               let tabManager = AppDelegate.shared?.tabManager,
               let tabId = tabManager.selectedTabId {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                DispatchQueue.main.async {
                    tabManager.moveTabToTop(tabId)
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE,
               action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                defaultBackgroundColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                if backgroundLogEnabled {
                    logBackground("OSC background change (app target) color=\(defaultBackgroundColor)")
                }
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                updateDefaultBackground(from: action.action.config_change.config)
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return false }
        let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: action.action.goto_split),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId,
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.scrollbar = scrollbar
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
            )
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            surfaceView.cellSize = cellSize
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateCellSize,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.cellSize: cellSize]
            )
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.title: title,
                        ]
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = surfaceView.tabId else { return true }
            let surfaceId = surfaceView.terminalSurface?.id
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
            let command = actionTitle.isEmpty ? tabTitle : actionTitle
            let body = actionBody
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.moveTabToTop(tabId)
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                surfaceView.backgroundColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                surfaceView.applySurfaceBackground()
                if backgroundLogEnabled {
                    logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                }
                DispatchQueue.main.async {
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            updateDefaultBackground(from: action.action.config_change.config)
            DispatchQueue.main.async {
                surfaceView.applyWindowBackgroundIfActive()
            }
            return true
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return performOnMain {
                surfaceView.updateKeySequence(action.action.key_sequence)
                return true
            }
        case GHOSTTY_ACTION_KEY_TABLE:
            return performOnMain {
                surfaceView.updateKeyTable(action.action.key_table)
                return true
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let color = defaultBackgroundColor.withAlphaComponent(defaultBackgroundOpacity)
        window.backgroundColor = color
        window.isOpaque = color.alphaComponent >= 1.0
        if backgroundLogEnabled {
            logBackground("applied default window background color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
        }
    }

    func logBackground(_ message: String) {
        let line = "cmux bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

class TerminalSurface: Identifiable {
    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?
    let id: UUID
    let tabId: UUID
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: ghostty_surface_config_s?
    private let workingDirectory: String?
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    private var ownsDisplayLink = false

    init(
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: ghostty_surface_config_s?,
        workingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let view = GhosttyNSView(frame: .zero)
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        // Surface is created when attached to a view
        hostedView.attachSurface(self)
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let layerScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        guard view.bounds.width > 0 && view.bounds.height > 0 else {
            return (layerScale, layerScale, layerScale)
        }
        let backingBounds = view.convertToBacking(view.bounds)
        let xScale = backingBounds.width / view.bounds.width
        let yScale = backingBounds.height / view.bounds.height
        return (xScale, yScale, layerScale)
    }

    func attachToView(_ view: GhosttyNSView) {
        // If already attached to this view, nothing to do
        if attachedView === view && surface != nil {
            updateMetalLayer(for: view)
            return
        }

        if let attachedView, attachedView !== view {
            return
        }

        attachedView = view

        // If surface doesn't exist yet, create it
        if surface == nil {
            createSurface(for: view)
        }
    }

    private func createSurface(for view: GhosttyNSView) {
        guard let app = GhosttyApp.shared.app else {
            print("Ghostty app not initialized")
            return
        }

        let scaleFactors = scaleFactors(for: view)

        updateMetalLayer(for: view)

        var surfaceConfig = configTemplate ?? ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env: [String: String] = [:]
        if surfaceConfig.env_var_count > 0, let existingEnv = surfaceConfig.env_vars {
            let count = Int(surfaceConfig.env_var_count)
            if count > 0 {
                for i in 0..<count {
                    let item = existingEnv[i]
                    if let key = String(cString: item.key, encoding: .utf8),
                       let value = String(cString: item.value, encoding: .utf8) {
                        env[key] = value
                    }
                }
            }
        }

        env["CMUX_PANEL_ID"] = id.uuidString
        env["CMUX_TAB_ID"] = tabId.uuidString
        env["CMUX_SOCKET_PATH"] = SocketControlSettings.socketPath()

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                let separator = currentPath.isEmpty ? "" : ":"
                env["PATH"] = "\(cliBinPath)\(separator)\(currentPath)"
            }
        }

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            workingDirectory.withCString { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                createSurface()
            }
        } else {
            createSurface()
        }

        if surface == nil {
            print("Failed to create ghostty surface")
            return
        }

        ghostty_surface_set_content_scale(surface, scaleFactors.x, scaleFactors.y)
        ghostty_surface_set_size(
            surface,
            UInt32(view.bounds.width * scaleFactors.x),
            UInt32(view.bounds.height * scaleFactors.y)
        )
        ghostty_surface_refresh(surface)
        if !ownsDisplayLink {
            GhosttyApp.shared.retainDisplayLink()
            ownsDisplayLink = true
        }
    }

    private func updateMetalLayer(for view: GhosttyNSView) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            if view.bounds.width > 0 && view.bounds.height > 0 {
                metalLayer.drawableSize = CGSize(
                    width: view.bounds.width * scale,
                    height: view.bounds.height * scale
                )
            }
        }
    }

    func updateSize(width: CGFloat, height: CGFloat, xScale: CGFloat, yScale: CGFloat, layerScale: CGFloat) {
        guard let surface = surface else { return }
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(surface, UInt32(width * xScale), UInt32(height * yScale))
        ghostty_surface_refresh(surface)

        if let view = attachedView, let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = layerScale
            metalLayer.drawableSize = CGSize(width: width * layerScale, height: height * layerScale)
        }
    }

    func renderIfVisible() {
        guard let view = attachedView else { return }
        guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return }
        ghostty_surface_draw(surface)
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    func setFocus(_ focused: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func needsConfirmClose() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func sendText(_ text: String) {
        guard let surface = surface else { return }
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    deinit {
        if ownsDisplayLink {
            GhosttyApp.shared.releaseDisplayLink()
        }
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    weak var terminalSurface: TerminalSurface?
    private var surfaceAttached = false
    var scrollbar: GhosttyScrollbar?
    var cellSize: CGSize = .zero
    var desiredFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return metalLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        installEventMonitor()
        updateTrackingAreas()
    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let color = effectiveBackgroundColor()
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.backgroundColor = color.cgColor
            metalLayer.isOpaque = color.alphaComponent >= 1.0
        }
        terminalSurface?.hostedView.setBackgroundColor(color)
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        if let tabId, let selectedId = AppDelegate.shared?.tabManager?.selectedTabId, tabId != selectedId {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        window.backgroundColor = color
        window.isOpaque = color.alphaComponent >= 1.0
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground("applied window background tab=\(tabId?.uuidString ?? "unknown") color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }

        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        terminalSurface = surface
        tabId = surface.tabId
        surfaceAttached = false
        attachSurfaceIfNeeded()
    }

    private func attachSurfaceIfNeeded() {
        guard !surfaceAttached else { return }
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard window != nil else { return }

        surfaceAttached = true
        terminalSurface.attachToView(self)
        terminalSurface.setFocus(desiredFocus)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                self?.windowDidChangeScreen(notification)
            }
            attachSurfaceIfNeeded()
            updateSurfaceSize()
            applySurfaceBackground()
            applyWindowBackgroundIfActive()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attachSurfaceIfNeeded()
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        attachSurfaceIfNeeded()
    }

    override var isOpaque: Bool { false }

    private func updateSurfaceSize() {
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let backingBounds = convertToBacking(bounds)
        let xScale = backingBounds.width / bounds.width
        let yScale = backingBounds.height / bounds.height
        let layerScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        terminalSurface.updateSize(
            width: bounds.width,
            height: bounds.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale
        )
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        default:
            return true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            onFocus?()
#if DEBUG
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        return super.resignFirstResponder()
    }

    // For NSTextInputClient - accumulates text during key events
    private var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()
    private var lastPerformKeyEvent: TimeInterval?

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard window?.firstResponder === self else { return false }
        guard let surface = surface else { return false }

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = event.characters ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
            let isPerformable = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            if isConsumed && !isAll && !isPerformable && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Only handle command/control-modified keys here.
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Let the input system handle the event (for IME, dead keys, etc.)
        interpretKeyEvents([translationEvent])

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.composing = markedText.length > 0
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Use accumulated text from insertText (for IME), or compute text for key
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                if let name = String(data: data, encoding: .utf8) {
                    keyTables.append(name)
                }
            }
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(withTitle: "Trigger Flash", action: #selector(triggerFlash(_:)), keyEquivalent: "")
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            item.target = self
        }
        let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        return menu
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        terminalSurface?.setFocus(true)
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let title = "ghostty.title"
}

extension Notification.Name {
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }

        if let surface = surfaceView.terminalSurface?.surface,
           ghostty_surface_mouse_captured(surface) {
            surfaceView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class GhosttySurfaceScrollView: NSView {
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var isActive = true
    private var focusWorkItem: DispatchWorkItem?
#if DEBUG
    private static var flashCounts: [UUID: Int] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }
#endif

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor =
            GhosttyApp.shared.defaultBackgroundColor
                .withAlphaComponent(GhosttyApp.shared.defaultBackgroundOpacity)
                .cgColor
        addSubview(backgroundView)
        addSubview(scrollView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = NSColor.systemBlue.cgColor
        flashLayer.lineWidth = 3
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = NSColor.systemBlue.cgColor
        flashLayer.shadowOpacity = 0.6
        flashLayer.shadowRadius = 6
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(surfaceView)
        return true
    }

    override func resignFirstResponder() -> Bool {
        _ = surfaceView.resignFirstResponder()
        return true
    }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        flashOverlayView.frame = bounds
        updateFlashPath()
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
            self?.requestFocus()
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
        })
        updateFocusForWindow()
        if window.isKeyWindow { requestFocus() }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        surfaceView.onFocus = handler
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    func setBackgroundColor(_ color: NSColor) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    func triggerFlash() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath()
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 1, 0, 1, 0]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = 0.9
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
            self.flashLayer.add(animation, forKey: "cmux.flash")
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateFocusForWindow()
        if active {
            requestFocus()
        } else {
            cancelFocusRequest()
        }
    }

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.moveFocus(from: previous, delay: nextDelay)
                return
            }

            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)
        }

        let queue = DispatchQueue.main
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    func ensureFocus(for tabId: UUID, surfaceId: UUID, attempt: Int = 0) {
        let maxAttempts = 6
        guard attempt < maxAttempts else { return }
        guard let tabManager = AppDelegate.shared?.tabManager,
              tabManager.selectedTabId == tabId,
              tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }

        guard let window else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        guard window.isKeyWindow else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        if window.firstResponder === surfaceView {
            return
        }

        window.makeFirstResponder(surfaceView)

        if window.firstResponder !== surfaceView {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
        }
    }

    private func scheduleFocusRetry(for tabId: UUID, surfaceId: UUID, attempt: Int) {
        let delay = 0.05 * pow(2.0, Double(attempt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ensureFocus(for: tabId, surfaceId: surfaceId, attempt: attempt + 1)
        }
    }

    private func updateFocusForWindow() {
        let shouldFocus = isActive && (window?.isKeyWindow ?? false)
        surfaceView.desiredFocus = shouldFocus
        surfaceView.terminalSurface?.setFocus(shouldFocus)
    }

    private func requestFocus(delay: TimeInterval? = nil) {
        guard isActive else { return }
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        cancelFocusRequest()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isActive else { return }
            guard let window = self.window else {
                self.requestFocus(delay: nextDelay)
                return
            }
            guard window.isKeyWindow else { return }

            if window.firstResponder === self.surfaceView {
                return
            }

            if let responder = window.firstResponder as? NSView, responder !== self.surfaceView {
                _ = responder.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)

            if window.firstResponder !== self.surfaceView {
                self.requestFocus(delay: nextDelay)
            }
        }

        let queue = DispatchQueue.main
        focusWorkItem = work
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private func cancelFocusRequest() {
        focusWorkItem?.cancel()
        focusWorkItem = nil
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func updateFlashPath() {
        let inset: CGFloat = 2
        let radius: CGFloat = 6
        let bounds = flashOverlayView.bounds
        flashLayer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            flashLayer.path = nil
            return
        }
        let rect = bounds.insetBy(dx: inset, dy: inset)
        flashLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(scrollbar.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }
}

// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        let viewRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Otherwise send directly to the terminal
        if let surface = surface {
            chars.withCString { ptr in
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = 0
                keyEvent.mods = GHOSTTY_MODS_NONE
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = ptr
                keyEvent.composing = false
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    let terminalSurface: TerminalSurface
    var isActive: Bool = true
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    func makeNSView(context: Context) -> GhosttySurfaceScrollView {
        let view = terminalSurface.hostedView
        view.attachSurface(terminalSurface)
        view.setActive(isActive)
        view.setFocusHandler { onFocus?(terminalSurface.id) }
        view.setTriggerFlashHandler(onTriggerFlash)
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceScrollView, context: Context) {
        nsView.attachSurface(terminalSurface)
        nsView.setActive(isActive)
        nsView.setFocusHandler { onFocus?(terminalSurface.id) }
        nsView.setTriggerFlashHandler(onTriggerFlash)
    }
}
