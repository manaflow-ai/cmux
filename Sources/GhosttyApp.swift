import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    enum ScrollbarVisibility: String {
        case system
        case never
    }

    static let shared = GhosttyApp()
    private static let releaseBundleIdentifier = "com.cmuxterm.app"
    private static let fallbackAppearanceConfig = GhosttyConfig()
    private static let initializationLogger = Logger(
        subsystem: releaseBundleIdentifier,
        category: "ghostty.initialization"
    )
    // SAFETY: Ghostty C callbacks can run while GhosttyApp.shared is still initializing.
    // cmux owns one process-lifetime GhosttyApp, so the registry avoids singleton re-entry
    // without adding a teardown path for a ghostty_app_t that is never freed/recreated.
    private static let appRegistryLock = NSLock()
    private static var appRegistry: [UInt: GhosttyApp] = [:]
    private static var initializingRuntimeApp: GhosttyApp?
    private static let backgroundLogTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// Coalesce wakeup → tick dispatches.  The I/O thread may fire wakeup_cb
    /// thousands of times per second during bulk output.  We only need one
    /// pending tick on the main queue at any time.
    private var _tickScheduled = false
    private let _tickLock = NSLock()
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    private(set) var defaultBackgroundBlur: GhosttyBackgroundBlur = .disabled
    private(set) var defaultForegroundColor: NSColor = GhosttyApp.fallbackAppearanceConfig.foregroundColor
    private(set) var defaultCursorColor: NSColor = GhosttyApp.fallbackAppearanceConfig.cursorColor
    private(set) var defaultCursorTextColor: NSColor = GhosttyApp.fallbackAppearanceConfig.cursorTextColor
    private(set) var defaultSelectionBackground: NSColor = GhosttyApp.fallbackAppearanceConfig.selectionBackground
    private(set) var defaultSelectionForeground: NSColor = GhosttyApp.fallbackAppearanceConfig.selectionForeground
    private(set) var effectiveTerminalColorSchemePreference: GhosttyConfig.ColorSchemePreference = .dark
    private var appliedGhosttyRuntimeColorScheme: ghostty_color_scheme_e?
    private var runtimeColorSchemeSynchronizationDepth = 0
    private var reloadConfigurationDepth = 0
    private(set) var usesHostLayerBackground = false
    private(set) var userGhosttyShellIntegrationMode: String = "detect"

    static func retainTickNotifications() -> () -> Void {
        GhosttyTickNotificationDemand.retain()
    }

    private static func resolveBackgroundLogURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicitPath = environment["CMUX_DEBUG_BG_LOG"],
           !explicitPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: explicitPath)
        }

        if let debugLogPath = environment["CMUX_DEBUG_LOG"],
           !debugLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseURL = URL(fileURLWithPath: debugLogPath)
            let extensionSeparatorIndex = baseURL.lastPathComponent.lastIndex(of: ".")
            let stem = extensionSeparatorIndex.map { String(baseURL.lastPathComponent[..<$0]) } ?? baseURL.lastPathComponent
            let bgName = "\(stem)-bg.log"
            return baseURL.deletingLastPathComponent().appendingPathComponent(bgName)
        }

        return URL(fileURLWithPath: "/tmp/cmux-bg.log")
    }

#if DEBUG
    private static func debugDescription(
        for preparedContent: TerminalImageTransferPreparedContent
    ) -> String {
        switch preparedContent {
        case .insertText(let text):
            return "insertText(length:\(text.utf8.count),hasNewlines:\(text.contains(where: \.isNewline) ? 1 : 0))"
        case .fileURLs(let fileURLs):
            return "fileURLs(count:\(fileURLs.count))"
        case .reject:
            return "reject"
        }
    }
#endif

    static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let callbackContext = Self.callbackContext(from: userdata),
              let requestSurface = callbackContext.runtimeSurface else { return false }

        DispatchQueue.main.async {
            func completeClipboardRequest(with text: String) {
                let finish = {
                    guard callbackContext.runtimeSurface == requestSurface else { return }
                    text.withCString { ptr in
                        ghostty_surface_complete_clipboard_request(requestSurface, ptr, state, false)
                    }
                    callbackContext.terminalSurface?.noteClipboardReadCompleted()
                }
                if Thread.isMainThread {
                    finish()
                } else {
                    DispatchQueue.main.async(execute: finish)
                }
            }

            guard let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location) else {
                completeClipboardRequest(with: "")
                return
            }

            let preparedContent = TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .paste
            )

#if DEBUG
            cmuxDebugLog(
                "terminal.clipboard.read surface=\(callbackContext.surfaceId.uuidString.prefix(5)) " +
                "types=\((pasteboard.types ?? []).map(\.rawValue).joined(separator: ",")) " +
                "prepared=\(Self.debugDescription(for: preparedContent))"
            )
#endif

            switch preparedContent {
            case .reject:
                completeClipboardRequest(with: "")
            case .insertText(let text):
                completeClipboardRequest(with: text)
            case .fileURLs(let fileURLs):
                let operation = TerminalImageTransferOperation()
                MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.hostedView.beginImageTransferIndicator(
                        for: operation,
                        onCancel: {
                            completeClipboardRequest(with: "")
                        }
                    )
                }

                let target = MainActor.assumeIsolated {
                    callbackContext.terminalSurface?.resolvedImageTransferTarget() ?? .local
                }
                let plan = TerminalImageTransferPlanner.plan(
                    fileURLs: fileURLs,
                    target: target
                )

                TerminalImageTransferPlanner.execute(
                    plan: plan,
                    operation: operation,
                    uploadWorkspaceRemote: { fileURLs, operation, finish in
                        guard let workspace = MainActor.assumeIsolated({
                            callbackContext.terminalSurface?.owningWorkspace()
                        }) else {
                            finish(.failure(NSError(domain: "cmux.remote.paste", code: 3)))
                            GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            return
                        }
                        workspace.uploadDroppedFilesForRemoteTerminal(
                            fileURLs,
                            operation: operation,
                            completion: { result in
                                finish(result)
                                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            }
                        )
                    },
                    uploadDetectedSSH: { session, fileURLs, operation, finish in
                        session.uploadDroppedFiles(
                            fileURLs,
                            operation: operation,
                            completion: { result in
                                finish(result)
                                GhosttyPasteboardHelper.cleanupTransferredTemporaryImageFiles(fileURLs)
                            }
                        )
                    },
                    insertText: { text in
                        MainActor.assumeIsolated {
                            callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                for: operation
                            )
                        }
                        completeClipboardRequest(with: text)
                    },
                    onFailure: { _ in
                        MainActor.assumeIsolated {
                            callbackContext.terminalSurface?.hostedView.endImageTransferIndicator(
                                for: operation
                            )
                        }
                        NSSound.beep()
#if DEBUG
                        cmuxDebugLog("terminal.remotePasteUpload.failed surface=\(callbackContext.surfaceId.uuidString.prefix(5))")
#endif
                        completeClipboardRequest(with: "")
                    }
                )
            }
        }

        return true
    }

    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"] != nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxDebugBG")
    }()
    private let backgroundLogURL = GhosttyApp.resolveBackgroundLogURL()
    private let backgroundLogStartUptime = ProcessInfo.processInfo.systemUptime
    private let backgroundLogLock = NSLock()
    private var backgroundLogSequence: UInt64 = 0
    private var appObservers: [NSObjectProtocol] = []
    private var bellAudioSound: NSSound?
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"
    private var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?
    private lazy var defaultBackgroundNotificationDispatcher: GhosttyDefaultBackgroundNotificationDispatcher =
        // Theme chrome should track terminal theme changes in the same frame.
        // Keep coalescing semantics, but flush in the next main turn instead of waiting ~1 frame.
        GhosttyDefaultBackgroundNotificationDispatcher(delay: 0, logEvent: { [weak self] message in
            guard let self, self.backgroundLogEnabled else { return }
            self.logBackground(message)
        })

    // Scroll lag tracking
    private(set) var isScrolling = false
    private var scrollLagSampleCount = 0
    private var scrollLagTotalMs: Double = 0
    private var scrollLagMaxMs: Double = 0
    private let scrollLagThresholdMs: Double = 40
    private let scrollLagMinimumSamples = 8
    private let scrollLagMinimumAverageMs: Double = 12
    private let scrollLagReportCooldownSeconds: TimeInterval = 300
    private var lastScrollLagReportUptime: TimeInterval?
    private var scrollEndTimer: DispatchWorkItem?

    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end timer
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrolling = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrolling = true
            let timer = DispatchWorkItem { [weak self] in
                self?.endScrollSession()
            }
            scrollEndTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
        }
    }

    private func endScrollSession() {
        guard isScrolling else { return }
        isScrolling = false

        // Report accumulated lag stats if any exceeded threshold
        if scrollLagSampleCount > 0 {
            let avgLag = scrollLagTotalMs / Double(scrollLagSampleCount)
            let maxLag = scrollLagMaxMs
            let samples = scrollLagSampleCount
            let threshold = scrollLagThresholdMs
            let nowUptime = ProcessInfo.processInfo.systemUptime
            if Self.shouldCaptureScrollLagEvent(
                samples: samples,
                averageMs: avgLag,
                maxMs: maxLag,
                thresholdMs: threshold,
                minimumSamples: scrollLagMinimumSamples,
                minimumAverageMs: scrollLagMinimumAverageMs,
                nowUptime: nowUptime,
                lastReportedUptime: lastScrollLagReportUptime,
                cooldown: scrollLagReportCooldownSeconds
            ) {
                if TelemetrySettings.enabledForCurrentLaunch {
                    SentrySDK.capture(message: "Scroll lag detected") { scope in
                        scope.setLevel(.warning)
                        scope.setContext(value: [
                            "samples": samples,
                            "avg_ms": String(format: "%.2f", avgLag),
                            "max_ms": String(format: "%.2f", maxLag),
                            "threshold_ms": threshold
                        ], key: "scroll_lag")
                    }
                }
                lastScrollLagReportUptime = nowUptime
            }
            // Reset stats
            scrollLagSampleCount = 0
            scrollLagTotalMs = 0
            scrollLagMaxMs = 0
        }
    }

    private init() {
        initializeGhostty()
    }

    #if DEBUG
    private static let initLogPath = "/tmp/cmux-ghostty-init.log"

    private static func initLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: initLogPath) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            FileManager.default.createFile(atPath: initLogPath, contents: line.data(using: .utf8))
        }
    }

    private static func dumpConfigDiagnostics(_ config: ghostty_config_t, label: String) {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else {
            initLog("ghostty diagnostics (\(label)): none")
            return
        }
        initLog("ghostty diagnostics (\(label)): count=\(count)")
        for i in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, UInt32(i))
            let msg = diag.message.flatMap { String(cString: $0) } ?? "(null)"
            initLog("  [\(i)] \(msg)")
        }
    }
    #endif

    private static func reportInitializationFailure(
        _ message: String,
        data: [String: Any] = [:]
    ) {
        if data.isEmpty {
            initializationLogger.error("\(message, privacy: .public)")
        } else {
            initializationLogger.error("\(message, privacy: .public) \(String(describing: data), privacy: .public)")
        }
        sentryCaptureError(
            message,
            category: "terminal",
            data: data,
            contextKey: "ghostty.initialization"
        )
    }

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            #if DEBUG
            cmuxDebugLog("ghostty.initialize.failed result=\(result)")
            #endif
            Self.reportInitializationFailure(
                "ghostty.initialize.failed",
                data: ["result": Int(result)]
            )
            return
        }

        // Load config
        guard let primaryConfig = ghostty_config_new() else {
            #if DEBUG
            cmuxDebugLog("ghostty.initialize.config.failed")
            #endif
            Self.reportInitializationFailure("ghostty.initialize.config.failed")
            return
        }

        let initialColorScheme = GhosttyConfig.currentColorSchemePreference()

        // Load default config (includes user config). If this fails hard (e.g. due to
        // invalid user config), ghostty_app_new may return nil; we fall back below.
        let primaryRenderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            primaryConfig,
            preferredColorScheme: initialColorScheme
        )
        updateDefaultBackground(
            from: primaryConfig,
            source: "initialize.primaryConfig",
            forceNotify: primaryRenderingModeChanged
        )
        updateDefaultBackgroundFromResolvedGhosttyConfig(
            source: "initialize.primaryConfig",
            preferredColorScheme: initialColorScheme,
            baselineConfig: primaryConfig,
            forceNotify: primaryRenderingModeChanged
        )

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            GhosttyApp.runtimeApp(from: userdata)?.scheduleTick()
        }
        runtimeConfig.action_cb = { app, target, action in
            guard let runtimeApp = GhosttyApp.runtimeAppForActionCallback(app) else { return false }
            return runtimeApp.handleAction(target: target, action: action)
        }
        // Some GhosttyKit builds import this callback as returning `Void` in Swift even
        // though the C ABI returns `bool`. Store the C-compatible shim explicitly so the
        // project compiles against both importer variants.
        runtimeConfig.read_clipboard_cb = unsafeBitCast(
            cmuxRuntimeReadClipboardCallback as @convention(c) (
                UnsafeMutableRawPointer?,
                ghostty_clipboard_e,
                UnsafeMutableRawPointer?
            ) -> Bool,
            to: ghostty_runtime_read_clipboard_cb.self
        )
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata),
                  let surface = callbackContext.runtimeSurface else { return }

            ghostty_surface_complete_clipboard_request(surface, content, state, true)
            DispatchQueue.main.async {
                callbackContext.terminalSurface?.noteClipboardReadCompleted()
            }
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
        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            let callbackSurfaceId = callbackContext.surfaceId
            let callbackTabId = callbackContext.tabId

#if DEBUG
            cmuxWriteChildExitProbe(
                [
                    "probeCloseSurfaceNeedsConfirm": needsConfirmClose ? "1" : "0",
                    "probeCloseSurfaceTabId": callbackTabId?.uuidString ?? "",
                    "probeCloseSurfaceSurfaceId": callbackSurfaceId.uuidString,
                ],
                increments: ["probeCloseSurfaceCbCount": 1]
            )
#endif

            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                guard let callbackSurface = callbackContext.terminalSurface else {
#if DEBUG
                    cmuxDebugLog(
                        "surface.closeCallback.ignore surface=\(callbackSurfaceId.uuidString.prefix(5)) reason=missingCallbackSurface"
                    )
#endif
                    return
                }
                if let registeredSurface = TerminalSurfaceRegistry.shared.surface(id: callbackSurfaceId),
                   registeredSurface !== callbackSurface {
#if DEBUG
                    cmuxDebugLog(
                        "surface.closeCallback.ignore surface=\(callbackSurfaceId.uuidString.prefix(5)) reason=staleCallbackSurface"
                    )
#endif
                    return
                }
                // Close requests must be resolved by the callback's workspace/surface IDs only.
                // If the mapping is already gone (duplicate/stale callback), ignore it.
                if let callbackTabId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    if needsConfirmClose {
                        manager.closeRuntimeSurfaceWithConfirmation(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    } else {
                        manager.closeRuntimeSurface(
                            tabId: callbackTabId,
                            surfaceId: callbackSurfaceId
                        )
                    }
                }
            }
        }

        // Create app
        Self.setInitializingRuntimeApp(self)
        defer { Self.setInitializingRuntimeApp(nil) }

        if let created = ghostty_app_new(&runtimeConfig, primaryConfig) {
            self.app = created
            self.config = primaryConfig
            Self.registerRuntimeApp(self, for: created)
        } else {
            #if DEBUG
            Self.initLog("ghostty_app_new(primary) failed; attempting fallback config")
            Self.dumpConfigDiagnostics(primaryConfig, label: "primary")
            #endif

            // If the user config is invalid, prefer a minimal fallback configuration so
            // cmux still launches with working terminals.
            ghostty_config_free(primaryConfig)

            guard let fallbackConfig = ghostty_config_new() else {
                #if DEBUG
                cmuxDebugLog("ghostty.initialize.fallbackConfig.failed")
                #endif
                Self.reportInitializationFailure("ghostty.initialize.fallbackConfig.failed")
                return
            }

            loadInlineGhosttyConfig(
                "macos-background-from-layer = true",
                into: fallbackConfig,
                prefix: "cmux-renderer-bg",
                logLabel: "renderer background (fallback)"
            )
            loadInlineGhosttyConfig(
                "macos-titlebar-proxy-icon = hidden",
                into: fallbackConfig,
                prefix: "cmux-titlebar-proxy-icon",
                logLabel: "titlebar proxy icon (fallback)"
            )
            loadInlineGhosttyConfig(
                "shell-integration = none",
                into: fallbackConfig,
                prefix: "cmux-shell-integration-override",
                logLabel: "shell integration override (fallback)"
            )
            loadCmuxManagedTerminalSettingsConfig(fallbackConfig)
            loadCmuxOwnedGhosttyKeybindOverrides(fallbackConfig)
            loadNoActiveDisplayVsyncFallbackIfNeeded(fallbackConfig)
            let fallbackRenderingModeChanged = setUsesHostLayerBackground(
                true,
                source: "initialize.fallbackConfig"
            )
            ghostty_config_finalize(fallbackConfig)
            updateDefaultBackground(
                from: fallbackConfig,
                source: "initialize.fallbackConfig",
                forceNotify: fallbackRenderingModeChanged
            )
            updateDefaultBackgroundFromResolvedGhosttyConfig(
                source: "initialize.fallbackConfig",
                preferredColorScheme: initialColorScheme,
                baselineConfig: fallbackConfig,
                useOnDiskResolvedConfig: false,
                forceNotify: fallbackRenderingModeChanged
            )

            guard let created = ghostty_app_new(&runtimeConfig, fallbackConfig) else {
                #if DEBUG
                Self.initLog("ghostty_app_new(fallback) failed")
                Self.dumpConfigDiagnostics(fallbackConfig, label: "fallback")
                #endif
                #if DEBUG
                cmuxDebugLog("ghostty.initialize.app.failed")
                #endif
                Self.reportInitializationFailure("ghostty.initialize.app.failed")
                ghostty_config_free(fallbackConfig)
                return
            }

            self.app = created
            self.config = fallbackConfig
            Self.registerRuntimeApp(self, for: created)
        }

        // Notify observers that a usable config is available (initial load).
        synchronizeGhosttyRuntimeColorScheme(effectiveTerminalColorSchemePreference, source: "initialize")
        lastAppearanceColorScheme = initialColorScheme
        GhosttyConfig.invalidateLoadCache()
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)

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

        appObservers.append(NotificationCenter.default.addObserver(
            forName: TerminalCopyOnSelectSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadConfiguration(source: "settings.terminal.copyOnSelect")
        })

        #endif
    }

    private func loadInlineGhosttyConfig(
        _ contents: String,
        into config: ghostty_config_t,
        prefix: String,
        logLabel _: String
    ) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let syntheticPath = "/__cmux_inline__/\(prefix).conf"
        trimmed.withCString { contents in
            syntheticPath.withCString { path in
                ghostty_config_load_string(
                    config,
                    contents,
                    UInt(trimmed.lengthOfBytes(using: .utf8)),
                    path
                )
            }
        }
    }

    private func loadCmuxDefaultAppearanceConfig(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        if let url = GhosttyConfig.cmuxDefaultThemeConfigURL(preferredColorScheme: preferredColorScheme) {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            return
        }

        loadInlineGhosttyConfig(
            GhosttyConfig.cmuxDefaultThemeConfigContents(preferredColorScheme: preferredColorScheme),
            into: config,
            prefix: "cmux-default-appearance",
            logLabel: "default appearance fallback"
        )
    }

    private func loadCmuxManagedTerminalSettingsConfig(_ config: ghostty_config_t) {
        guard let contents = TerminalManagedGhosttySettings.ghosttyConfigContents() else { return }
        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-managed-terminal-settings",
            logLabel: "managed terminal settings"
        )
    }

    private func loadStartupPreviewProfile(
        _ profile: GhosttyStartupAppearancePreviewProfile,
        into config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        if profile == .freshInstall {
            loadCmuxDefaultAppearanceConfig(
                config,
                preferredColorScheme: preferredColorScheme
            )
            return
        }

        guard let contents = profile.previewConfigContents(
            preferredColorScheme: preferredColorScheme
        ) else { return }
        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-startup-preview",
            logLabel: "startup appearance preview"
        )
    }

    private func loadConditionalThemeOverrideIfNeeded(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        guard let contents = Self.conditionalThemeOverrideConfigContents(
            preferredColorScheme: preferredColorScheme
        ) else { return }

        loadInlineGhosttyConfig(
            contents,
            into: config,
            prefix: "cmux-conditional-theme",
            logLabel: "conditional theme override"
        )
    }

    func loadDefaultConfigFilesWithLegacyFallback(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference(),
        conditionalThemeColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) -> Bool {
        // Surface-only reloads may use a terminal-derived scheme for background
        // handling, while Ghostty split-theme pairs follow app appearance.
        let themeColorScheme = conditionalThemeColorScheme ?? preferredColorScheme

        #if DEBUG
        let startupPreviewProfile = GhosttyStartupAppearancePreviewState.profile
        if startupPreviewProfile.loadsRealUserConfig {
            ghostty_config_load_default_files(config)
            loadLegacyGhosttyConfigIfNeeded(config)
            loadCmuxAppSupportGhosttyConfigIfNeeded(config)
            ghostty_config_load_recursive_files(config)
            loadConditionalThemeOverrideIfNeeded(
                config,
                preferredColorScheme: themeColorScheme
            )
            if Self.shouldApplyManagedDefaultAppearance() {
                loadCmuxDefaultAppearanceConfig(
                    config,
                    preferredColorScheme: preferredColorScheme
                )
            }
        } else {
            loadStartupPreviewProfile(
                startupPreviewProfile,
                into: config,
                preferredColorScheme: preferredColorScheme
            )
        }
        #else
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        loadCmuxAppSupportGhosttyConfigIfNeeded(config)
        ghostty_config_load_recursive_files(config)
        loadConditionalThemeOverrideIfNeeded(
            config,
            preferredColorScheme: themeColorScheme
        )
        if Self.shouldApplyManagedDefaultAppearance() {
            loadCmuxDefaultAppearanceConfig(
                config,
                preferredColorScheme: preferredColorScheme
            )
        }
        #endif
        loadCJKFontFallbackIfNeeded(config)
        let renderingModeChanged = setUsesHostLayerBackground(
            true,
            source: "loadDefaultConfigFilesWithLegacyFallback"
        )
        // Let cmux own the window-level backdrop once, while Ghostty keeps
        // rendering text, cell backgrounds, and background images. This avoids
        // separate translucent fills for terminal and chrome surfaces.
        loadInlineGhosttyConfig(
            "macos-background-from-layer = true",
            into: config,
            prefix: "cmux-renderer-bg",
            logLabel: "renderer background"
        )
        // Hide Ghostty's native AppKit proxy icon at the source instead of
        // overriding NSWindow.representedURL on every cmux main window.
        loadInlineGhosttyConfig(
            "macos-titlebar-proxy-icon = hidden",
            into: config,
            prefix: "cmux-titlebar-proxy-icon",
            logLabel: "titlebar proxy icon"
        )
        // Save the user's preference before we force it to none.
        userGhosttyShellIntegrationMode = "detect"
        do {
            var value: UnsafePointer<Int8>?
            let key = "shell-integration"
            if ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
               let value {
                userGhosttyShellIntegrationMode = String(cString: value)
            }
        }

        // Prevent Ghostty from overriding ZDOTDIR — cmux handles shell
        // integration itself via the .zshenv bootstrap (#2594).
        loadInlineGhosttyConfig(
            "shell-integration = none",
            into: config,
            prefix: "cmux-shell-integration-override",
            logLabel: "shell integration override"
        )
        loadCmuxManagedTerminalSettingsConfig(config)
        loadCmuxOwnedGhosttyKeybindOverrides(config)
        loadNoActiveDisplayVsyncFallbackIfNeeded(config)

        ghostty_config_finalize(config)
        return renderingModeChanged
    }

    private func loadNoActiveDisplayVsyncFallbackIfNeeded(_ config: ghostty_config_t) {
        var displayCount: UInt32 = 0
        let error = CGGetActiveDisplayList(0, nil, &displayCount)
        guard error == .success, displayCount == 0 else { return }

        loadInlineGhosttyConfig(
            "window-vsync = false",
            into: config,
            prefix: "cmux-no-active-display-vsync-fallback",
            logLabel: "no active display vsync fallback"
        )
#if DEBUG
        cmuxDebugLog("ghostty.vsync.disable reason=noActiveDisplays")
#endif
    }

    private func loadCmuxOwnedGhosttyKeybindOverrides(_ config: ghostty_config_t) {
        // cmux owns these split and close shortcuts through KeyboardShortcutSettings.
        // Remove Ghostty's default fallbacks so remapped or cleared shortcuts
        // can reach the focused terminal instead of splitting or closing outside
        // the remappable shortcut layer.
        loadInlineGhosttyConfig(
            """
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            """,
            into: config,
            prefix: "cmux-owned-keybind-overrides",
            logLabel: "cmux-owned keybind overrides"
        )
    }

    /// When the user has not configured `font-codepoint-map` for CJK ranges
    /// and has not already provided an explicit multi-entry `font-family`
    /// fallback chain, Ghostty's `CTFontCollection` scoring may pick an
    /// inappropriate fallback font for Hiragana, Katakana, and CJK symbols.
    /// The scoring prioritizes monospace fonts, so decorative fonts with
    /// monospace attributes (e.g. AB_appare from Adobe CC, or LingWai) can be
    /// selected depending on what is installed. This injects a sensible
    /// default based on the system's preferred languages without overriding
    /// user-managed fallback chains or configured fonts that already cover
    /// the affected CJK ranges.
    ///
    /// See: https://github.com/manaflow-ai/cmux/pull/1017
    private func loadCJKFontFallbackIfNeeded(_ config: ghostty_config_t) {
        guard let mappings = Self.autoInjectedCJKFontMappings() else { return }

        var resolvedFonts: [String: String] = [:]
        let lines = mappings.map { range, font in
            let resolvedFont = resolvedFonts[font] ?? {
                let resolved = Self.resolvedInjectedCJKFontName(named: font)
                resolvedFonts[font] = resolved
                return resolved
            }()
            return "font-codepoint-map = \(range)=\(resolvedFont)"
        }.joined(separator: "\n")
        loadInlineGhosttyConfig(
            lines,
            into: config,
            prefix: "cmux-cjk-font-fallback",
            logLabel: "CJK font fallback"
        )
    }

    /// Unicode ranges shared by all CJK languages (Han ideographs, symbols, fullwidth forms).
    private static let sharedCJKRanges = [
        "U+3000-U+303F",  // CJK Symbols and Punctuation
        "U+4E00-U+9FFF",  // CJK Unified Ideographs
        "U+F900-U+FAFF",  // CJK Compatibility Ideographs
        "U+FF00-U+FFEF",  // Halfwidth and Fullwidth Forms
        "U+3400-U+4DBF",  // CJK Unified Ideographs Extension A
    ]

    /// Unicode ranges specific to Japanese (kana).
    private static let japaneseRanges = [
        "U+3040-U+309F",  // Hiragana
        "U+30A0-U+30FF",  // Katakana
    ]

    /// Representative scalars used to detect whether the configured primary
    /// font already covers the ranges cmux would otherwise auto-map.
    private static let cjkCoverageSampleCharactersByRange: [String: [UniChar]] = [
        "U+3000-U+303F": [0x3001, 0x300C],
        "U+4E00-U+9FFF": [0x4E00, 0x65E5, 0x6C34],
        "U+F900-U+FAFF": [0xF900],
        "U+FF00-U+FFEF": [0xFF10, 0xFF21],
        "U+3400-U+4DBF": [0x3400],
        "U+1100-U+11FF": [0x1100, 0x1161],
        "U+3130-U+318F": [0x3131, 0x314F],
        "U+3040-U+309F": [0x3042, 0x3093],
        "U+30A0-U+30FF": [0x30A2, 0x30F3],
        "U+AC00-U+D7AF": [0xAC00, 0xD55C],
    ]

    private struct UserFontConfigSummary {
        var containsCodepointMap = false
        var effectiveFontFamilies: [String] = []

        var hasExplicitFontFamilyFallbackChain: Bool {
            effectiveFontFamilies.count > 1
        }

        mutating func applyFontCodepointMap(_ value: String) {
            if value.isEmpty {
                containsCodepointMap = false
                return
            }

            guard value.contains("=") else {
                return
            }

            containsCodepointMap = true
        }

        mutating func recordFontFamily(_ value: String) {
            if value.isEmpty {
                effectiveFontFamilies.removeAll()
                return
            }

            guard !effectiveFontFamilies.contains(value) else {
                return
            }

            effectiveFontFamilies.append(value)
        }
    }

    private struct UserAppearanceConfigSummary {
        var hasThemeDirective = false
        var hasExplicitTerminalColorDirective = false
        var lastThemeDirective: String?

        var shouldApplyDefaultAppearance: Bool {
            !hasThemeDirective && !hasExplicitTerminalColorDirective
        }

        mutating func recordDirective(key: String, value: String?) {
            switch key {
            case "theme":
                hasThemeDirective = true
                let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lastThemeDirective = trimmedValue.isEmpty ? nil : trimmedValue
            case "background",
                 "foreground",
                 "palette",
                 "cursor-color",
                 "cursor-text",
                 "selection-background",
                 "selection-foreground":
                hasExplicitTerminalColorDirective = true
            default:
                break
            }
        }
    }

    /// Returns (range, font) pairs for CJK font fallback based on the system's
    /// preferred languages, or nil if no CJK language is detected. Each language
    /// only maps its own script ranges to avoid assigning glyphs to a font that
    /// lacks coverage (e.g. Hangul to Hiragino Sans).
    static func cjkFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [(String, String)]? {
        var mappings: [(String, String)] = []
        var coveredShared = false

        for lang in preferredLanguages {
            let lower = lang.lowercased()
            let font: String
            var langRanges: [String] = []

            if lower.hasPrefix("ja") {
                font = "Hiragino Sans"
                langRanges = japaneseRanges
            } else if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
                font = "PingFang TC"
            } else if lower.hasPrefix("zh") {
                font = "PingFang SC"
            } else {
                continue
            }

            if !coveredShared {
                for range in sharedCJKRanges {
                    mappings.append((range, font))
                }
                coveredShared = true
            }

            for range in langRanges {
                mappings.append((range, font))
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Returns only the CJK mappings cmux should auto-inject after respecting
    /// explicit user overrides and the glyph coverage of the configured
    /// primary font family.
    static func autoInjectedCJKFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> [(String, String)]? {
        guard var mappings = cjkFontMappings(preferredLanguages: preferredLanguages) else { return nil }

        let summary = userFontConfigSummary(configPaths: configPaths)
        if summary.containsCodepointMap || summary.hasExplicitFontFamilyFallbackChain {
            return nil
        }

        guard let configuredFontFamily = summary.effectiveFontFamilies.first else {
            return mappings
        }

        if let rangeCoverageProbe {
            mappings.removeAll { range, _ in
                rangeCoverageProbe(configuredFontFamily, range)
            }
        } else if let configuredFont = configuredCTFont(named: configuredFontFamily) {
            mappings.removeAll { range, _ in
                fontContainsGlyphs(configuredFont, forRange: range)
            }
        }

        return mappings.isEmpty ? nil : mappings
    }

    /// Checks whether the user's Ghostty config files already contain
    /// a `font-codepoint-map` entry covering CJK ranges. Also checks
    /// application-support config paths that cmux may load at runtime.
    static func userConfigContainsCJKCodepointMap(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).containsCodepointMap
    }

    static func userConfigHasExplicitFontFamilyFallbackChain(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userFontConfigSummary(configPaths: configPaths).hasExplicitFontFamilyFallbackChain
    }

    static func shouldInjectCJKFontFallback(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String] = loadedCJKScanPaths(),
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> Bool {
        autoInjectedCJKFontMappings(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        ) != nil
    }

    static func shouldApplyManagedDefaultAppearance(
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> Bool {
        userAppearanceConfigSummary(configPaths: configPaths).shouldApplyDefaultAppearance
    }

    static func conditionalThemeOverrideConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        configPaths: [String] = loadedGhosttyConfigScanPaths()
    ) -> String? {
        let summary = userAppearanceConfigSummary(configPaths: configPaths)
        guard let rawThemeValue = summary.lastThemeDirective else { return nil }

        let lightTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: .light
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let darkTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: .dark
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lightTheme.isEmpty,
              !darkTheme.isEmpty,
              lightTheme.caseInsensitiveCompare(darkTheme) != .orderedSame else {
            return nil
        }

        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: rawThemeValue,
            preferredColorScheme: preferredColorScheme
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedTheme.isEmpty,
              resolvedTheme.rangeOfCharacter(from: .newlines) == nil else {
            return nil
        }

        return "theme = \(resolvedTheme)"
    }

    /// Resolve auto-injected CJK families through the regular-weight descriptor
    /// path first so locale-sensitive families such as Hiragino Sans don't fall
    /// back to ultra-light faces like W0 when Ghostty later matches by name.
    static func resolvedInjectedCJKFontName(
        named name: String,
        size: CGFloat = 12
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        guard let regularWeightFont = discoveredCTFont(named: trimmed, size: size, weightTrait: 0.0) else {
            return trimmed
        }

        let candidateNames = [
            CTFontCopyName(regularWeightFont, kCTFontFullNameKey) as String?,
            CTFontCopyName(regularWeightFont, kCTFontPostScriptNameKey) as String?,
        ].compactMap { $0 }
        let expectedFullName = CTFontCopyFullName(regularWeightFont) as String
        let expectedPostScriptName = CTFontCopyPostScriptName(regularWeightFont) as String

        for candidate in candidateNames {
            guard let verifiedFont = discoveredCTFont(named: candidate, size: size) else { continue }
            let verifiedNames = [
                CTFontCopyName(verifiedFont, kCTFontFamilyNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontFullNameKey) as String?,
                CTFontCopyName(verifiedFont, kCTFontPostScriptNameKey) as String?,
            ].compactMap { $0 }
            let matchesRegularWeightFace = verifiedNames.contains {
                normalizedFontName($0) == normalizedFontName(expectedFullName) ||
                normalizedFontName($0) == normalizedFontName(expectedPostScriptName)
            }
            if matchesRegularWeightFace {
                return candidate
            }
        }

        return trimmed
    }

    private static func configuredCTFont(
        named name: String,
        size: CGFloat = 12
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let font = CTFontCreateWithName(trimmed as CFString, size, nil)
        let normalizedRequestedName = normalizedFontName(trimmed)
        let resolvedNames = [
            kCTFontFamilyNameKey,
            kCTFontFullNameKey,
            kCTFontPostScriptNameKey,
        ].compactMap { CTFontCopyName(font, $0) as String? }

        guard resolvedNames.contains(where: { normalizedFontName($0) == normalizedRequestedName }) else {
            return nil
        }

        return font
    }

    /// Mirror Ghostty's family-name CoreText discovery path so injected
    /// `font-codepoint-map` values are validated against the same lookup mode.
    static func discoveredCTFont(
        named name: String,
        size: CGFloat = 12,
        weightTrait: CGFloat? = nil
    ) -> CTFont? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: trimmed,
            kCTFontSizeAttribute: size,
        ]
        if let weightTrait {
            attributes[kCTFontTraitsAttribute] = [
                kCTFontWeightTrait: weightTrait,
            ] as CFDictionary
        }

        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let collection = CTFontCollectionCreateWithFontDescriptors([descriptor] as CFArray, nil)
        guard let match = (CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor])?.first else {
            return nil
        }
        return CTFontCreateWithFontDescriptor(match, size, nil)
    }

    private static func fontContainsGlyphs(
        _ font: CTFont,
        forRange range: String
    ) -> Bool {
        guard let characters = cjkCoverageSampleCharactersByRange[range] else {
            return false
        }

        var glyphs = Array(repeating: CGGlyph(), count: characters.count)
        let hasGlyphs = CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return hasGlyphs && !glyphs.contains(0)
    }

    private static func normalizedFontName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func userFontConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserFontConfigSummary {
        var summary = UserFontConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        var loadedRecursivePaths = Set<String>()
        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            let resolved = (path as NSString).standardizingPath
            guard !loadedRecursivePaths.contains(resolved) else { continue }
            loadedRecursivePaths.insert(resolved)

            scanFontConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    private static func userAppearanceConfigSummary(
        configPaths: [String] = loadedCJKScanPaths()
    ) -> UserAppearanceConfigSummary {
        var summary = UserAppearanceConfigSummary()
        var recursiveConfigPaths: [String] = []

        for path in configPaths.map({ NSString(string: $0).expandingTildeInPath }) {
            scanAppearanceConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        var loadedRecursivePaths = Set<String>()
        while !recursiveConfigPaths.isEmpty {
            let path = recursiveConfigPaths.removeFirst()
            let resolved = (path as NSString).standardizingPath
            guard !loadedRecursivePaths.contains(resolved) else { continue }
            loadedRecursivePaths.insert(resolved)

            scanAppearanceConfigFile(
                atPath: path,
                summary: &summary,
                recursiveConfigPaths: &recursiveConfigPaths
            )
        }

        return summary
    }

    /// Returns the top-level Ghostty config paths cmux may load before
    /// recursive `config-file` processing.
    static func loadedGhosttyConfigScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        var paths = [
            "~/.config/ghostty/config",
            "~/.config/ghostty/config.ghostty",
        ]

        guard let appSupportDirectory else { return paths }

        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        paths.append(nativeConfig.path)
        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: configFileSize(at: nativeConfig),
            legacyConfigFileSize: configFileSize(at: nativeLegacyConfig)
        ) {
            paths.append(nativeLegacyConfig.path)
        }

        guard let bundleId = currentBundleIdentifier,
              !bundleId.isEmpty else { return paths }

        let appSupportConfigURLs = cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleId,
            appSupportDirectory: appSupportDirectory
        )
        paths.append(contentsOf: appSupportConfigURLs.map(\.path))

        let releaseDir = appSupportDirectory.appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
        let releaseLegacyConfig = releaseDir.appendingPathComponent("config", isDirectory: false)
        let releaseConfig = releaseDir.appendingPathComponent("config.ghostty", isDirectory: false)

        let releaseConfigSize = configFileSize(at: releaseConfig)
        let releaseLegacyConfigSize = configFileSize(at: releaseLegacyConfig)

        if shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: releaseConfigSize,
            legacyConfigFileSize: releaseLegacyConfigSize
        ), !paths.contains(releaseLegacyConfig.path) {
            paths.append(releaseLegacyConfig.path)
        }

        return paths
    }

    static func loadedCJKScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    private static func configFileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Scans a single config file for font settings relevant to cmux's
    /// injected CJK fallback and updates the pending recursive config-file
    /// queue using Ghostty's repeatable path semantics.
    private static func scanFontConfigFile(
        atPath path: String,
        summary: inout UserFontConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "font-codepoint-map":
                guard let value = entry.value else { continue }
                summary.applyFontCodepointMap(value)
            case "font-family":
                guard let value = entry.value else { continue }
                summary.recordFontFamily(value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
                    value,
                    valueWasQuoted: entry.valueWasQuoted,
                    parentDir: parentDir,
                    recursiveConfigPaths: &recursiveConfigPaths
                )
            default:
                continue
            }
        }
    }

    private static func scanAppearanceConfigFile(
        atPath path: String,
        summary: inout UserAppearanceConfigSummary,
        recursiveConfigPaths: inout [String]
    ) {
        let resolved = (path as NSString).standardizingPath
        guard let contents = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return
        }
        let parentDir = (resolved as NSString).deletingLastPathComponent

        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedConfigEntry(from: line) else { continue }

            switch entry.key {
            case "theme",
                 "background",
                 "foreground",
                 "palette",
                 "cursor-color",
                 "cursor-text",
                 "selection-background",
                 "selection-foreground":
                summary.recordDirective(key: entry.key, value: entry.value)
            case "config-file":
                guard let value = entry.value else { continue }
                applyConfigFileDirective(
                    value,
                    valueWasQuoted: entry.valueWasQuoted,
                    parentDir: parentDir,
                    recursiveConfigPaths: &recursiveConfigPaths
                )
            default:
                continue
            }
        }
    }

    private static func parsedConfigEntry(
        from rawLine: String
    ) -> (key: String, value: String?, valueWasQuoted: Bool)? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        guard let separatorIndex = trimmed.firstIndex(of: "=") else {
            return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), nil, false)
        }

        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed[trimmed.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valueWasQuoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")

        if valueWasQuoted {
            value.removeFirst()
            value.removeLast()
        }

        return (String(key), String(value), valueWasQuoted)
    }

    private static func applyConfigFileDirective(
        _ value: String,
        valueWasQuoted: Bool,
        parentDir: String,
        recursiveConfigPaths: inout [String]
    ) {
        if value.isEmpty {
            recursiveConfigPaths.removeAll()
            return
        }

        var includePath = value
        if !valueWasQuoted, includePath.hasPrefix("?") {
            includePath.removeFirst()
            if includePath.count >= 2,
               includePath.hasPrefix("\""),
               includePath.hasSuffix("\"") {
                includePath.removeFirst()
                includePath.removeLast()
            }
        }
        guard !includePath.isEmpty else { return }

        let expanded = NSString(string: includePath).expandingTildeInPath
        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (parentDir as NSString).appendingPathComponent(expanded)
        recursiveConfigPaths.append(absolute)
    }

    static func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        return newConfigFileSize == 0
    }

    static func shouldIncludeLegacyGhosttyConfigInScanPaths(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        guard let legacyConfigFileSize, legacyConfigFileSize > 0 else { return false }
        guard let newConfigFileSize else { return true }
        return newConfigFileSize == 0
    }

    static func shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> Bool {
        guard let appSupportDirectory else { return false }
        let ghosttyDir = appSupportDirectory.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let nativeLegacyConfig = ghosttyDir.appendingPathComponent("config", isDirectory: false)
        let nativeConfig = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        guard let legacyConfigSize = configFileSize(at: nativeLegacyConfig), legacyConfigSize > 0 else {
            return false
        }
        guard let nativeConfigSize = configFileSize(at: nativeConfig), nativeConfigSize > 0 else {
            return false
        }
        return true
    }

    static func cmuxAppSupportConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        CmuxGhosttyConfigPathResolver.loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
    }

    static func shouldApplyDefaultBackgroundUpdate(
        currentScope: GhosttyDefaultBackgroundUpdateScope,
        incomingScope: GhosttyDefaultBackgroundUpdateScope
    ) -> Bool {
        incomingScope.rawValue >= currentScope.rawValue
    }

    static func shouldReloadConfigurationForAppearanceChange(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> Bool {
        previousColorScheme != currentColorScheme
    }

    enum AppearanceSynchronizationPlan {
        case unchanged
        case reload(
            colorScheme: GhosttyConfig.ColorSchemePreference,
            runtimeColorScheme: ghostty_color_scheme_e
        )

        var shouldReloadConfiguration: Bool {
            switch self {
            case .unchanged:
                return false
            case .reload:
                return true
            }
        }
    }

    enum RuntimeColorSchemeSynchronizationDecision: Equatable {
        case apply
        case skipReentrant
    }

    static func runtimeColorSchemeSynchronizationDecision(
        applied _: ghostty_color_scheme_e?,
        requested _: ghostty_color_scheme_e,
        isSynchronizing: Bool
    ) -> RuntimeColorSchemeSynchronizationDecision {
        if isSynchronizing {
            return .skipReentrant
        }
        return .apply
    }

    static func appearanceSynchronizationPlan(
        previousColorScheme: GhosttyConfig.ColorSchemePreference?,
        currentColorScheme: GhosttyConfig.ColorSchemePreference
    ) -> AppearanceSynchronizationPlan {
        guard shouldReloadConfigurationForAppearanceChange(
            previousColorScheme: previousColorScheme,
            currentColorScheme: currentColorScheme
        ) else {
            return .unchanged
        }

        return .reload(
            colorScheme: currentColorScheme,
            runtimeColorScheme: ghosttyRuntimeColorScheme(for: currentColorScheme)
        )
    }

    static func ghosttyRuntimeColorScheme(
        for colorScheme: GhosttyConfig.ColorSchemePreference
    ) -> ghostty_color_scheme_e {
        switch colorScheme {
        case .light:
            return GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark:
            return GHOSTTY_COLOR_SCHEME_DARK
        }
    }

    static func terminalRuntimeColorSchemePreference(
        forBackgroundColor backgroundColor: NSColor
    ) -> GhosttyConfig.ColorSchemePreference {
        cmuxReadableColorScheme(for: backgroundColor) == .light ? .light : .dark
    }

    static func runtimeColorSchemeForConfigLoad(
        source: String,
        requestedColorScheme: GhosttyConfig.ColorSchemePreference,
        effectiveTerminalColorScheme: GhosttyConfig.ColorSchemePreference,
        cmuxThemeValue: String?
    ) -> GhosttyConfig.ColorSchemePreference {
        guard GhosttySurfaceConfigurationRefresh.isCmuxThemeReloadSource(source),
              let cmuxThemeValue,
              GhosttyConfig.themeValueUsesSameResolvedThemeInBothColorSchemes(cmuxThemeValue) else {
            return requestedColorScheme
        }

        return effectiveTerminalColorScheme
    }

    static func shouldCaptureScrollLagEvent(
        samples: Int,
        averageMs: Double,
        maxMs: Double,
        thresholdMs: Double,
        minimumSamples: Int = 8,
        minimumAverageMs: Double = 12,
        nowUptime: TimeInterval,
        lastReportedUptime: TimeInterval?,
        cooldown: TimeInterval = 300
    ) -> Bool {
        guard samples >= minimumSamples else { return false }
        guard averageMs.isFinite, maxMs.isFinite, thresholdMs.isFinite, nowUptime.isFinite, cooldown.isFinite else {
            return false
        }
        guard averageMs >= minimumAverageMs else { return false }
        guard maxMs > thresholdMs else { return false }
        if let lastReportedUptime, nowUptime - lastReportedUptime < cooldown {
            return false
        }
        return true
    }

    private func loadCmuxAppSupportGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        guard let currentBundleIdentifier = Bundle.main.bundleIdentifier,
              !currentBundleIdentifier.isEmpty else { return }
        let urls = Self.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )
        guard !urls.isEmpty else { return }

        for url in urls {
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        }

#if DEBUG
        cmuxDebugLog(
            "loaded cmux app support ghostty config from: \(urls.map(\.path).joined(separator: ", "))"
        )
        #endif
        #endif
    }

    private func currentCmuxAppSupportThemeValue() -> String? {
        #if os(macOS)
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let urls = Self.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            appSupportDirectory: appSupport,
            fileManager: fm
        )

        var lastValue: String?
        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                  let value = GhosttyConfig.lastThemeDirective(in: contents) else {
                continue
            }
            lastValue = value
        }
        return lastValue
        #else
        return nil
        #endif
    }

    private func loadLegacyGhosttyConfigIfNeeded(_ config: ghostty_config_t) {
        #if os(macOS)
        // Ghostty 1.3+ prefers `config.ghostty`, but some users still have their real
        // settings in the legacy `config` file. Use legacy only when `config.ghostty`
        // is absent or empty, so stale legacy files do not override current config.
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let ghosttyDir = appSupport.appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        let configNew = ghosttyDir.appendingPathComponent("config.ghostty", isDirectory: false)
        let configLegacy = ghosttyDir.appendingPathComponent("config", isDirectory: false)

        func fileSize(_ url: URL) -> Int? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return nil }
            return size.intValue
        }

        guard Self.shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: fileSize(configNew),
            legacyConfigFileSize: fileSize(configLegacy)
        ) else { return }

        configLegacy.path.withCString { path in
            ghostty_config_load_file(config, path)
        }

        #if DEBUG
        Self.initLog("loaded legacy ghostty config because config.ghostty was empty: \(configLegacy.path)")
        #endif
        #endif
    }

    /// Schedule a single tick on the main queue, coalescing multiple wakeups.
    func scheduleTick() {
        _tickLock.lock()
        defer { _tickLock.unlock() }
        guard !_tickScheduled else { return }
        _tickScheduled = true
        DispatchQueue.main.async {
            self.tick()
        }
    }

    func tick() {
        _tickLock.lock()
        _tickScheduled = false
        _tickLock.unlock()

        guard let app = app else { return }

        let start = CACurrentMediaTime()
        ghostty_app_tick(app)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        if GhosttyTickNotificationDemand.isActive {
            NotificationCenter.default.post(name: .ghosttyDidTick, object: self)
        }

        // Track lag during scrolling
        if isScrolling {
            scrollLagSampleCount += 1
            scrollLagTotalMs += elapsedMs
            scrollLagMaxMs = max(scrollLagMaxMs, elapsedMs)
        }
    }

    func reloadConfiguration(
        soft: Bool = false,
        source: String = "unspecified",
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard reloadConfigurationDepth == 0 else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=reentrant")
            return
        }
        reloadConfigurationDepth += 1
        defer { reloadConfigurationDepth -= 1 }

        if reloadSettingsFromFile {
            KeyboardShortcutSettings.settingsFileStore.reload()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                AppDelegate.shared?.reloadCmuxConfigStores(source: source)
            }
        } else {
            DispatchQueue.main.sync {
                AppDelegate.shared?.reloadCmuxConfigStores(source: source)
            }
        }
        let reloadColorScheme = preferredColorScheme ?? GhosttyConfig.currentColorSchemePreference()
        guard let app else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=no_app")
            return
        }
        // Use the appearance preference while loading conditional theme pairs. For cmux
        // single-theme reloads, keep the resolved terminal scheme stable until the new
        // background is known so same-scheme theme changes do not flash through app mode.
        let loadColorScheme = Self.runtimeColorSchemeForConfigLoad(
            source: source,
            requestedColorScheme: reloadColorScheme,
            effectiveTerminalColorScheme: effectiveTerminalColorSchemePreference,
            cmuxThemeValue: currentCmuxAppSupportThemeValue()
        )
        synchronizeGhosttyRuntimeColorScheme(loadColorScheme, source: "reloadConfiguration:\(source):load")
        logThemeAction("reload begin source=\(source) soft=\(soft)")
        resetDefaultBackgroundUpdateScope(source: "reloadConfiguration(source=\(source))")
        if soft, let config {
            let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
            ghostty_app_update_config(app, config)
            lastAppearanceColorScheme = reloadColorScheme
            GhosttyConfig.invalidateLoadCache()
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            scheduleSurfaceRefreshAfterConfigurationReload(
                source: source,
                preferredColorScheme: effectiveReloadColorScheme
            )
            logThemeAction("reload end source=\(source) soft=\(soft) mode=soft")
            return
        }

        guard let newConfig = ghostty_config_new() else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=config_alloc_failed")
            return
        }
        let renderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            preferredColorScheme: reloadColorScheme
        )
        updateDefaultBackground(
            from: newConfig,
            source: "reloadConfiguration(source=\(source))",
            scope: .unscoped,
            forceNotify: renderingModeChanged
        )
        GhosttyConfig.invalidateLoadCache()
        updateDefaultBackgroundFromResolvedGhosttyConfig(
            source: "reloadConfiguration(source=\(source))",
            preferredColorScheme: reloadColorScheme,
            baselineConfig: newConfig,
            scope: .unscoped,
            forceNotify: renderingModeChanged
        )
        let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
        synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
        ghostty_app_update_config(app, newConfig)
        DispatchQueue.main.async {
            self.applyBackgroundToKeyWindow()
        }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        lastAppearanceColorScheme = reloadColorScheme
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
        scheduleSurfaceRefreshAfterConfigurationReload(
            source: source,
            preferredColorScheme: effectiveReloadColorScheme
        )
        logThemeAction("reload end source=\(source) soft=\(soft) mode=full")
    }

    private func scheduleSurfaceRefreshAfterConfigurationReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        DispatchQueue.main.async {
            AppDelegate.shared?.refreshTerminalSurfacesAfterGhosttyConfigReload(
                source: source,
                preferredColorScheme: preferredColorScheme
            )
        }
    }

    func synchronizeThemeWithAppearance(_: NSAppearance?, source: String) {
        let currentColorScheme = GhosttyConfig.currentColorSchemePreference()
        let plan = Self.appearanceSynchronizationPlan(
            previousColorScheme: lastAppearanceColorScheme,
            currentColorScheme: currentColorScheme
        )
        if backgroundLogEnabled {
            let previousLabel: String
            switch lastAppearanceColorScheme {
            case .light:
                previousLabel = "light"
            case .dark:
                previousLabel = "dark"
            case nil:
                previousLabel = "nil"
            }
            let currentLabel: String = currentColorScheme == .dark ? "dark" : "light"
            logBackground(
                "appearance sync source=\(source) previous=\(previousLabel) current=\(currentLabel) reload=\(plan.shouldReloadConfiguration)"
            )
        }
        guard case let .reload(colorScheme, runtimeColorScheme) = plan else { return }
        synchronizeGhosttyRuntimeColorScheme(
            runtimeColorScheme,
            colorScheme: colorScheme,
            source: source
        )
        lastAppearanceColorScheme = colorScheme
        reloadConfiguration(
            source: "appearanceSync:\(source)",
            reloadSettingsFromFile: false,
            preferredColorScheme: colorScheme
        )
    }

    private func synchronizeGhosttyRuntimeColorScheme(
        _ colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        synchronizeGhosttyRuntimeColorScheme(
            Self.ghosttyRuntimeColorScheme(for: colorScheme),
            colorScheme: colorScheme,
            source: source
        )
    }

    private func synchronizeGhosttyRuntimeColorScheme(
        _ runtimeColorScheme: ghostty_color_scheme_e,
        colorScheme: GhosttyConfig.ColorSchemePreference,
        source: String
    ) {
        guard let app else { return }
        let decision = Self.runtimeColorSchemeSynchronizationDecision(
            applied: appliedGhosttyRuntimeColorScheme,
            requested: runtimeColorScheme,
            isSynchronizing: runtimeColorSchemeSynchronizationDepth > 0
        )
        guard decision == .apply else {
            if backgroundLogEnabled {
                let schemeLabel = colorScheme == .dark ? "dark" : "light"
                let reason: String
                switch decision {
                case .apply:
                    reason = "apply"
                case .skipReentrant:
                    reason = "reentrant"
                }
                logBackground("app color scheme skipped source=\(source) scheme=\(schemeLabel) reason=\(reason)")
            }
            return
        }

        appliedGhosttyRuntimeColorScheme = runtimeColorScheme
        runtimeColorSchemeSynchronizationDepth += 1
        defer { runtimeColorSchemeSynchronizationDepth -= 1 }
        ghostty_app_set_color_scheme(app, runtimeColorScheme)
        if backgroundLogEnabled {
            let schemeLabel = colorScheme == .dark ? "dark" : "light"
            logBackground("app color scheme source=\(source) scheme=\(schemeLabel)")
        }
    }

    private func shouldProcessGhosttyReloadAction(source: String, soft: Bool) -> Bool {
        guard reloadConfigurationDepth == 0,
              runtimeColorSchemeSynchronizationDepth == 0 else {
            logThemeAction("reload request skipped source=\(source) soft=\(soft) reason=reentrant")
            return false
        }
        return true
    }

    func openConfigurationInTextEdit() {
        #if os(macOS)
        let environment = ConfigSourceEnvironment.live()
        let fileURLs: [URL]
        do {
            fileURLs = try environment.materializedGhosttySettingsEditorURLs()
        } catch {
            NSSound.beep()
            return
        }
        guard !fileURLs.isEmpty else {
            NSSound.beep()
            return
        }
        let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(fileURLs, withApplicationAt: editorURL, configuration: configuration)
        #endif
    }

    private func resetDefaultBackgroundUpdateScope(source: String) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        defaultBackgroundUpdateScope = .unscoped
        defaultBackgroundScopeSource = "reset:\(source)"
        if backgroundLogEnabled {
            logBackground(
                "default background scope reset source=\(source) previousScope=\(previousScope.logLabel) previousSource=\(previousScopeSource)"
            )
        }
    }

    @discardableResult
    private func setUsesHostLayerBackground(_ newValue: Bool, source: String) -> Bool {
        let previous = usesHostLayerBackground
        usesHostLayerBackground = newValue
        let hasChanged = previous != newValue
        if hasChanged, backgroundLogEnabled {
            logBackground(
                "terminal rendering mode changed source=\(source) usesHostLayerBackground=\(newValue) previous=\(previous)"
            )
        }
        return hasChanged
    }

    private func ghosttyColorValue(
        from config: ghostty_config_t,
        key: String,
        fallback: NSColor
    ) -> NSColor {
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return fallback
        }
        return NSColor(
            red: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1.0
        )
    }

    private func updateDefaultBackground(
        from config: ghostty_config_t?,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        forceNotify: Bool = false
    ) {
        guard let config else { return }

        let resolved = defaultBackgroundValues(from: config)
        applyDefaultBackground(
            color: resolved.backgroundColor,
            opacity: resolved.backgroundOpacity,
            backgroundBlur: resolved.backgroundBlur,
            foregroundColor: resolved.foregroundColor,
            cursorColor: resolved.cursorColor,
            cursorTextColor: resolved.cursorTextColor,
            selectionBackground: resolved.selectionBackground,
            selectionForeground: resolved.selectionForeground,
            source: source,
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private struct DefaultBackgroundValues {
        var backgroundColor: NSColor
        var backgroundOpacity: Double
        var backgroundBlur: GhosttyBackgroundBlur
        var foregroundColor: NSColor
        var cursorColor: NSColor
        var cursorTextColor: NSColor
        var selectionBackground: NSColor
        var selectionForeground: NSColor
    }

    private func defaultBackgroundValues(from config: ghostty_config_t?) -> DefaultBackgroundValues {
        let baseline = Self.fallbackAppearanceConfig
        guard let config else {
            return DefaultBackgroundValues(
                backgroundColor: baseline.backgroundColor,
                backgroundOpacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground
            )
        }

        let resolvedColor = ghosttyColorValue(from: config, key: "background", fallback: baseline.backgroundColor)
        let resolvedForeground = ghosttyColorValue(from: config, key: "foreground", fallback: baseline.foregroundColor)
        let resolvedCursor = ghosttyColorValue(from: config, key: "cursor-color", fallback: baseline.cursorColor)
        let resolvedCursorText = ghosttyColorValue(from: config, key: "cursor-text", fallback: baseline.cursorTextColor)
        let resolvedSelectionBackground = ghosttyColorValue(from: config, key: "selection-background", fallback: baseline.selectionBackground)
        let resolvedSelectionForeground = ghosttyColorValue(from: config, key: "selection-foreground", fallback: baseline.selectionForeground)
        var opacity = baseline.backgroundOpacity
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        opacity = min(1.0, max(0.0, opacity))
        let backgroundBlur = defaultBackgroundBlurValue(from: config)
        return DefaultBackgroundValues(
            backgroundColor: resolvedColor,
            backgroundOpacity: opacity,
            backgroundBlur: backgroundBlur,
            foregroundColor: resolvedForeground,
            cursorColor: resolvedCursor,
            cursorTextColor: resolvedCursorText,
            selectionBackground: resolvedSelectionBackground,
            selectionForeground: resolvedSelectionForeground
        )
    }

    private func resolvedAppearanceValue<T>(
        parsedValue: T,
        baselineValue: T,
        unspecifiedFallbackValue: T,
        hasParsedDirective: Bool,
        hasDirective: Bool
    ) -> T {
        if hasParsedDirective {
            return parsedValue
        }
        if hasDirective {
            return baselineValue
        }
        return unspecifiedFallbackValue
    }

    private func updateDefaultBackgroundFromResolvedGhosttyConfig(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        baselineConfig: ghostty_config_t?,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        useOnDiskResolvedConfig: Bool = true,
        forceNotify: Bool = false
    ) {
        let baseline = defaultBackgroundValues(from: baselineConfig)
        guard useOnDiskResolvedConfig else {
            applyDefaultBackground(
                color: baseline.backgroundColor,
                opacity: baseline.backgroundOpacity,
                backgroundBlur: baseline.backgroundBlur,
                foregroundColor: baseline.foregroundColor,
                cursorColor: baseline.cursorColor,
                cursorTextColor: baseline.cursorTextColor,
                selectionBackground: baseline.selectionBackground,
                selectionForeground: baseline.selectionForeground,
                source: source,
                scope: scope,
                forceNotify: forceNotify
            )
            return
        }
        let resolved = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false)
        let fallbackForUnspecified = Self.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance()
            ? defaultBackgroundValues(from: nil)
            : baseline
        applyDefaultBackground(
            color: resolvedAppearanceValue(
                parsedValue: resolved.backgroundColor,
                baselineValue: baseline.backgroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundColor,
                hasParsedDirective: resolved.hasParsedBackgroundColor,
                hasDirective: resolved.hasBackgroundColorDirective
            ),
            opacity: resolvedAppearanceValue(
                parsedValue: resolved.backgroundOpacity,
                baselineValue: baseline.backgroundOpacity,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundOpacity,
                hasParsedDirective: resolved.hasParsedBackgroundOpacity,
                hasDirective: resolved.hasBackgroundOpacityDirective
            ),
            backgroundBlur: resolvedAppearanceValue(
                parsedValue: resolved.backgroundBlur,
                baselineValue: baseline.backgroundBlur,
                unspecifiedFallbackValue: fallbackForUnspecified.backgroundBlur,
                hasParsedDirective: resolved.hasParsedBackgroundBlur,
                hasDirective: resolved.hasBackgroundBlurDirective
            ),
            foregroundColor: resolvedAppearanceValue(
                parsedValue: resolved.foregroundColor,
                baselineValue: baseline.foregroundColor,
                unspecifiedFallbackValue: fallbackForUnspecified.foregroundColor,
                hasParsedDirective: resolved.hasParsedForegroundColor,
                hasDirective: resolved.hasForegroundColorDirective
            ),
            cursorColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorColor,
                baselineValue: baseline.cursorColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorColor,
                hasParsedDirective: resolved.hasParsedCursorColor,
                hasDirective: resolved.hasCursorColorDirective
            ),
            cursorTextColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorTextColor,
                baselineValue: baseline.cursorTextColor,
                unspecifiedFallbackValue: fallbackForUnspecified.cursorTextColor,
                hasParsedDirective: resolved.hasParsedCursorTextColor,
                hasDirective: resolved.hasCursorTextColorDirective
            ),
            selectionBackground: resolvedAppearanceValue(
                parsedValue: resolved.selectionBackground,
                baselineValue: baseline.selectionBackground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionBackground,
                hasParsedDirective: resolved.hasParsedSelectionBackground,
                hasDirective: resolved.hasSelectionBackgroundDirective
            ),
            selectionForeground: resolvedAppearanceValue(
                parsedValue: resolved.selectionForeground,
                baselineValue: baseline.selectionForeground,
                unspecifiedFallbackValue: fallbackForUnspecified.selectionForeground,
                hasParsedDirective: resolved.hasParsedSelectionForeground,
                hasDirective: resolved.hasSelectionForegroundDirective
            ),
            source: "\(source).resolvedGhosttyConfig",
            scope: scope,
            forceNotify: forceNotify
        )
    }

    private func defaultBackgroundBlurValue(from config: ghostty_config_t) -> GhosttyBackgroundBlur {
        var value: Int16 = 0
        let key = "background-blur"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            return .disabled
        }
        return GhosttyBackgroundBlur(cValue: value)
    }

    func focusFollowsMouseEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "focus-follows-mouse"
        let keyLength = UInt(key.lengthOfBytes(using: .utf8))
        let found = ghostty_config_get(config, &enabled, key, keyLength)
        return found && enabled
    }

    func scrollbarVisibility() -> ScrollbarVisibility {
        guard let config else { return .system }
        var value: UnsafePointer<Int8>?
        let key = "scrollbar"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let value else {
            return .system
        }
        return ScrollbarVisibility(rawValue: String(cString: value)) ?? .system
    }

    func appleScriptAutomationEnabled() -> Bool {
        guard let config else { return false }
        var enabled = false
        let key = "macos-applescript"
        _ = ghostty_config_get(config, &enabled, key, UInt(key.lengthOfBytes(using: .utf8)))
        return enabled
    }

    private func bellFeatures() -> CUnsignedInt {
        guard let config else { return 0 }
        var features: CUnsignedInt = 0
        let key = "bell-features"
        _ = ghostty_config_get(config, &features, key, UInt(key.lengthOfBytes(using: .utf8)))
        return features
    }

    private func bellAudioPath() -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<Int8>?
        let key = "bell-audio-path"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))),
              let rawPath = value else {
            return nil
        }
        let path = String(cString: rawPath)
        return path.isEmpty ? nil : path
    }

    private func bellAudioVolume() -> Float {
        guard let config else { return 0.5 }
        var value: Double = 0.5
        let key = "bell-audio-volume"
        _ = ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
        return Float(min(1.0, max(0.0, value)))
    }

    private func ringBell() {
        let features = bellFeatures()

        if (features & (1 << 0)) != 0 {
            NSSound.beep()
        }

        if (features & (1 << 1)) != 0,
           let path = bellAudioPath(),
           let sound = NSSound(contentsOfFile: path, byReference: false) {
            sound.volume = bellAudioVolume()
            bellAudioSound = sound
            if !sound.play() {
                bellAudioSound = nil
            }
        }

        if (features & (1 << 2)) != 0 {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func applyDefaultBackground(
        color: NSColor,
        opacity: Double,
        backgroundBlur: GhosttyBackgroundBlur,
        foregroundColor: NSColor? = nil,
        cursorColor: NSColor? = nil,
        cursorTextColor: NSColor? = nil,
        selectionBackground: NSColor? = nil,
        selectionForeground: NSColor? = nil,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope,
        forceNotify: Bool = false
    ) {
        let previousScope = defaultBackgroundUpdateScope
        let previousScopeSource = defaultBackgroundScopeSource
        guard Self.shouldApplyDefaultBackgroundUpdate(currentScope: previousScope, incomingScope: scope) else {
            if backgroundLogEnabled {
                logBackground(
                    "default background skipped source=\(source) incomingScope=\(scope.logLabel) currentScope=\(previousScope.logLabel) currentSource=\(previousScopeSource) color=\(color.hexString()) opacity=\(String(format: "%.3f", opacity))"
                )
            }
            return
        }

        defaultBackgroundUpdateScope = scope
        defaultBackgroundScopeSource = source

        let previousHex = defaultBackgroundColor.hexString()
        let previousOpacity = defaultBackgroundOpacity
        let previousBlur = defaultBackgroundBlur
        let previousForegroundHex = defaultForegroundColor.hexString()
        let previousCursorHex = defaultCursorColor.hexString()
        let previousCursorTextHex = defaultCursorTextColor.hexString()
        let previousSelectionBackgroundHex = defaultSelectionBackground.hexString()
        let previousSelectionForegroundHex = defaultSelectionForeground.hexString()
        let previousColorScheme = effectiveTerminalColorSchemePreference
        defaultBackgroundColor = color
        defaultBackgroundOpacity = opacity
        defaultBackgroundBlur = backgroundBlur
        effectiveTerminalColorSchemePreference = Self.terminalRuntimeColorSchemePreference(
            forBackgroundColor: color
        )
        if let foregroundColor {
            defaultForegroundColor = foregroundColor
        }
        if let cursorColor {
            defaultCursorColor = cursorColor
        }
        if let cursorTextColor {
            defaultCursorTextColor = cursorTextColor
        }
        if let selectionBackground {
            defaultSelectionBackground = selectionBackground
        }
        if let selectionForeground {
            defaultSelectionForeground = selectionForeground
        }
        let hasChanged = forceNotify ||
            previousHex != defaultBackgroundColor.hexString() ||
            abs(previousOpacity - defaultBackgroundOpacity) > 0.0001 ||
            previousBlur != defaultBackgroundBlur ||
            previousForegroundHex != defaultForegroundColor.hexString() ||
            previousCursorHex != defaultCursorColor.hexString() ||
            previousCursorTextHex != defaultCursorTextColor.hexString() ||
            previousSelectionBackgroundHex != defaultSelectionBackground.hexString() ||
            previousSelectionForegroundHex != defaultSelectionForeground.hexString() ||
            previousColorScheme != effectiveTerminalColorSchemePreference
        if hasChanged {
            notifyDefaultBackgroundDidChange(source: source)
        }
        if backgroundLogEnabled {
            logBackground(
                "default appearance updated source=\(source) scope=\(scope.logLabel) previousScope=\(previousScope.logLabel) previousScopeSource=\(previousScopeSource) previousBg=\(previousHex) previousFg=\(previousForegroundHex) previousOpacity=\(String(format: "%.3f", previousOpacity)) previousBlur=\(previousBlur) previousScheme=\(previousColorScheme) bg=\(defaultBackgroundColor.hexString()) fg=\(defaultForegroundColor.hexString()) cursor=\(defaultCursorColor.hexString()) cursorText=\(defaultCursorTextColor.hexString()) selectionBg=\(defaultSelectionBackground.hexString()) selectionFg=\(defaultSelectionForeground.hexString()) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur) scheme=\(effectiveTerminalColorSchemePreference) changed=\(hasChanged) forced=\(forceNotify)"
            )
        }
    }

    private func nextBackgroundEventId() -> UInt64 {
        precondition(Thread.isMainThread, "Background event IDs must be generated on main thread")
        backgroundEventCounter &+= 1
        return backgroundEventCounter
    }

    private func notifyDefaultBackgroundDidChange(source: String) {
        let signal = { [self] in
            let eventId = nextBackgroundEventId()
            defaultBackgroundNotificationDispatcher.signal(
                backgroundColor: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                eventId: eventId,
                source: source,
                foregroundColor: defaultForegroundColor,
                cursorColor: defaultCursorColor,
                cursorTextColor: defaultCursorTextColor,
                selectionBackground: defaultSelectionBackground,
                selectionForeground: defaultSelectionForeground
            )
        }
        if Thread.isMainThread {
            signal()
        } else {
            DispatchQueue.main.async(execute: signal)
        }
    }

    private func logThemeAction(_ message: String) {
        guard backgroundLogEnabled else { return }
        logBackground("theme action \(message)")
    }

    private func actionLabel(for action: ghostty_action_s) -> String {
        switch action.tag {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return "reload_config"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return "config_change"
        case GHOSTTY_ACTION_COLOR_CHANGE:
            return "color_change"
        default:
            return String(describing: action.tag)
        }
    }

    private func logAction(_ action: ghostty_action_s, target: ghostty_target_s, tabId: UUID?, surfaceId: UUID?) {
        guard backgroundLogEnabled else { return }
        let targetLabel = target.tag == GHOSTTY_TARGET_SURFACE ? "surface" : "app"
        logBackground(
            "action event target=\(targetLabel) action=\(actionLabel(for: action)) tab=\(tabId?.uuidString ?? "nil") surface=\(surfaceId?.uuidString ?? "nil")"
        )
    }

    private func color(from change: ghostty_action_color_change_s) -> NSColor {
        NSColor(
            red: CGFloat(change.r) / 255,
            green: CGFloat(change.g) / 255,
            blue: CGFloat(change.b) / 255,
            alpha: 1.0
        )
    }

    private func colorKindLabel(_ kind: ghostty_action_color_kind_e) -> String {
        switch kind {
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            return "foreground"
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            return "background"
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            return "cursor"
        default:
            return "palette:\(kind.rawValue)"
        }
    }

    @MainActor
    private func applyAppColorChange(
        _ change: ghostty_action_color_change_s,
        source: String
    ) {
        let newColor = color(from: change)
        switch change.kind {
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            applyDefaultBackground(
                color: newColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                source: source,
                scope: .app
            )
            DispatchQueue.main.async {
                self.applyBackgroundToKeyWindow()
            }
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                foregroundColor: newColor,
                source: source,
                scope: .app
            )
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            applyDefaultBackground(
                color: defaultBackgroundColor,
                opacity: defaultBackgroundOpacity,
                backgroundBlur: defaultBackgroundBlur,
                cursorColor: newColor,
                source: source,
                scope: .app
            )
        default:
            if backgroundLogEnabled {
                logBackground(
                    "app color change ignored kind=\(colorKindLabel(change.kind)) color=\(newColor.hexString()) source=\(source)"
                )
            }
        }
    }

    private func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    @MainActor
    private static func openEmbeddedBrowserLink(
        url: URL,
        sourceWorkspaceId: UUID,
        sourcePanelId: UUID,
        host: String
    ) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
            #if DEBUG
            cmuxDebugLog("link.openURL deferred embedded but cmuxBrowser=disabled, opening externally url=\(url)")
            #endif
            return NSWorkspace.shared.open(url)
        }

        guard let app = AppDelegate.shared,
              let resolved = app.workspaceContainingPanel(
                panelId: sourcePanelId,
                preferredWorkspaceId: sourceWorkspaceId
              ) else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded but workspace lookup failed, opening externally " +
                "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        let workspace = resolved.workspace
        #if DEBUG
        if workspace.id != sourceWorkspaceId {
            cmuxDebugLog(
                "link.openURL workspace.remap sourceTab=\(sourceWorkspaceId) " +
                "resolvedTab=\(workspace.id) surfaceId=\(sourcePanelId)"
            )
        }
        #endif

        let openedInBrowser: Bool
        if let targetPane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            #if DEBUG
            cmuxDebugLog("link.openURL opening in existing browser pane=\(targetPane)")
            #endif
            openedInBrowser = workspace.newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
        } else {
            #if DEBUG
            cmuxDebugLog("link.openURL opening as new browser split from surface=\(sourcePanelId)")
            #endif
            openedInBrowser = workspace.newBrowserSplit(from: sourcePanelId, orientation: .horizontal, url: url) != nil
        }

        guard openedInBrowser else {
            #if DEBUG
            cmuxDebugLog(
                "link.openURL deferred embedded browser creation failed, opening externally " +
                "host=\(host) url=\(url)"
            )
            #endif
            return NSWorkspace.shared.open(url)
        }

        return true
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> NavigationDirection? {
        switch direction {
        // For previous/next, we use left/right as a reasonable default
        // Bonsplit doesn't have cycle-based navigation
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .left
        case GHOSTTY_GOTO_SPLIT_NEXT: return .right
        case GHOSTTY_GOTO_SPLIT_UP: return .up
        case GHOSTTY_GOTO_SPLIT_DOWN: return .down
        case GHOSTTY_GOTO_SPLIT_LEFT: return .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> ResizeDirection? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func runtimeApp(from userdata: UnsafeMutableRawPointer?) -> GhosttyApp? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func registerRuntimeApp(_ runtimeApp: GhosttyApp, for app: ghostty_app_t) {
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        appRegistry[key] = runtimeApp
        appRegistryLock.unlock()
    }

    private static func setInitializingRuntimeApp(_ runtimeApp: GhosttyApp?) {
        appRegistryLock.lock()
        initializingRuntimeApp = runtimeApp
        appRegistryLock.unlock()
    }

    private static func runtimeApp(for app: ghostty_app_t?) -> GhosttyApp? {
        guard let app else { return nil }
        let key = UInt(bitPattern: app)
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        return appRegistry[key]
    }

    private static func runtimeAppForActionCallback(_ app: ghostty_app_t?) -> GhosttyApp? {
        appRegistryLock.lock()
        defer { appRegistryLock.unlock() }
        if let app {
            let key = UInt(bitPattern: app)
            if let registered = appRegistry[key] {
                return registered
            }
        }
        return initializingRuntimeApp
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
                action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
                action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                logAction(action, target: target, tabId: nil, surfaceId: nil)
            }

            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                return performOnMain {
                    guard let tabManager = AppDelegate.shared?.tabManager,
                          let tabId = tabManager.selectedTabId else {
                        return false
                    }
                    let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? tabManager
                    let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                    if let workspace = owningManager.tabs.first(where: { $0.id == tabId }),
                       workspace.suppressesRawTerminalNotification(panelId: surfaceId) {
                        return true
                    }
                    let tabTitle = owningManager.titleForTab(tabId) ?? "Terminal"
                    let command = actionTitle.isEmpty ? tabTitle : actionTitle
                    let body = actionBody
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                    return true
                }
            }

            if action.tag == GHOSTTY_ACTION_RING_BELL {
                performOnMain {
                    self.ringBell()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                logThemeAction("reload request target=app soft=\(soft)")
                performOnMain {
                    guard self.shouldProcessGhosttyReloadAction(
                        source: "action.reload_config.app",
                        soft: soft
                    ) else {
                        return
                    }
                    self.reloadConfiguration(soft: soft, source: "action.reload_config.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
                performOnMain {
                    applyAppColorChange(action.action.color_change, source: "action.color_change.app")
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                // Theme picker preview reloads are resolved through reloadConfiguration.
                // Ghostty's config-change payload can still contain stale app defaults,
                // so it must not own the window chrome appearance.
                synchronizeGhosttyRuntimeColorScheme(
                    effectiveTerminalColorSchemePreference,
                    source: "action.config_change.app:resolved"
                )
                DispatchQueue.main.async {
                    self.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        let callbackContext = Self.callbackContext(from: ghostty_surface_userdata(target.target.surface))
        let callbackTabId = callbackContext?.tabId
        let callbackSurfaceId = callbackContext?.surfaceId

        if action.tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED {
            // The child (shell) exited. Ghostty will fall back to printing
            // "Process exited. Press any key..." into the terminal unless the host
            // handles this action. For cmux, the correct behavior is to close
            // the panel immediately (no prompt).
#if DEBUG
            cmuxDebugLog(
                "surface.action.showChildExited tab=\(callbackTabId?.uuidString.prefix(5) ?? "nil") " +
                "surface=\(callbackSurfaceId?.uuidString.prefix(5) ?? "nil")"
            )
#endif
#if DEBUG
            cmuxWriteChildExitProbe(
                [
                    "probeShowChildExitedTabId": callbackTabId?.uuidString ?? "",
                    "probeShowChildExitedSurfaceId": callbackSurfaceId?.uuidString ?? "",
                ],
                increments: ["probeShowChildExitedCount": 1]
            )
#endif
            // Keep host-close async to avoid re-entrant close/deinit while Ghostty is still
            // dispatching this action callback.
            DispatchQueue.main.async {
                guard let app = AppDelegate.shared else { return }
                if let callbackTabId,
                   let callbackSurfaceId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager,
                   let workspace = manager.tabs.first(where: { $0.id == callbackTabId }),
                   workspace.panels[callbackSurfaceId] != nil {
                    manager.closePanelAfterChildExited(tabId: callbackTabId, surfaceId: callbackSurfaceId)
                }
            }
            // Always report handled so Ghostty doesn't print the fallback prompt.
            return true
        }

        guard let surfaceView = callbackContext?.surfaceView else { return false }
        if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG ||
            action.tag == GHOSTTY_ACTION_CONFIG_CHANGE ||
            action.tag == GHOSTTY_ACTION_COLOR_CHANGE {
            logAction(
                action,
                target: target,
                tabId: callbackTabId ?? surfaceView.tabId,
                surfaceId: callbackSurfaceId ?? surfaceView.terminalSurface?.id
            )
        }

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split) else {
                return false
            }
            return performOnMain {
                guard let app = AppDelegate.shared,
                      let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
                    return false
                }
                return tabManager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
            }
        case GHOSTTY_ACTION_RING_BELL:
            performOnMain {
                self.ringBell()
            }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: action.action.goto_split) else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction) else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return false
            }
            return performOnMain {
                guard let tabManager = AppDelegate.shared?.tabManager else { return false }
                return tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_RENDER:
            return false
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.enqueueScrollbarUpdate(scrollbar)
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            DispatchQueue.main.async {
                surfaceView.cellSize = cellSize
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateCellSize,
                    object: surfaceView,
                    userInfo: [GhosttyNotificationKey.cellSize: cellSize]
                )
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            DispatchQueue.main.async {
                terminalSurface.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId,
               let surfaceId = surfaceView.terminalSurface?.id {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.surfaceId: surfaceId,
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
                AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateSurfaceDirectory(
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
            performOnMain {
                let owningManager = AppDelegate.shared?.tabManagerFor(tabId: tabId) ?? AppDelegate.shared?.tabManager
                if let workspace = owningManager?.tabs.first(where: { $0.id == tabId }),
                   workspace.suppressesRawTerminalNotification(panelId: surfaceId) {
                    return
                }
                let tabTitle = owningManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
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
            let change = action.action.color_change
            let newColor = color(from: change)
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                if backgroundLogEnabled {
                    logBackground(
                        "surface override set tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") override=\(newColor.hexString()) default=\(defaultBackgroundColor.hexString()) source=action.color_change.surface"
                    )
                }
                DispatchQueue.main.async { [self] in
                    surfaceView.backgroundColor = newColor
                    surfaceView.applySurfaceBackground()
                    if backgroundLogEnabled {
                        logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                    }
                    surfaceView.applyWindowBackgroundIfActive()
                }
            } else if backgroundLogEnabled {
                logBackground(
                    "surface color change observed tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") kind=\(colorKindLabel(change.kind)) color=\(newColor.hexString()) source=action.color_change.surface"
                )
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            DispatchQueue.main.async { [self] in
                if let staleOverride = surfaceView.backgroundColor {
                    surfaceView.backgroundColor = nil
                    if backgroundLogEnabled {
                        logBackground(
                            "surface override cleared tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") cleared=\(staleOverride.hexString()) source=action.config_change.surface"
                        )
                    }
                    surfaceView.applySurfaceBackground()
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            // Keep surface config-change handling scoped to the surface. The app-level
            // default background is owned by reloadConfiguration's resolved GhosttyConfig.
            let effectiveConfigChangeColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(
                effectiveConfigChangeColorScheme,
                source: "action.config_change.surface:resolved"
            )
            DispatchQueue.main.async {
                surfaceView.applySurfaceColorScheme(
                    force: true,
                    preferredColorScheme: effectiveConfigChangeColorScheme
                )
            }
            if backgroundLogEnabled {
                logBackground(
                    "surface config change deferred terminal bg apply tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") override=\(surfaceView.backgroundColor?.hexString() ?? "nil") default=\(defaultBackgroundColor.hexString())"
                )
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            let source = "action.reload_config.surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil")"
            logThemeAction(
                "reload request target=surface tab=\(surfaceView.tabId?.uuidString ?? "nil") surface=\(surfaceView.terminalSurface?.id.uuidString ?? "nil") soft=\(soft)"
            )
            return performOnMain {
                guard self.shouldProcessGhosttyReloadAction(source: source, soft: soft) else {
                    return true
                }
                let preferredColorScheme = self.effectiveTerminalColorSchemePreference
                surfaceView.terminalSurface?.hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                    preferredColorScheme: preferredColorScheme
                )
                self.reloadSurfaceConfiguration(
                    target.target.surface,
                    soft: soft,
                    source: source,
                    preferredColorScheme: preferredColorScheme
                )
                surfaceView.terminalSurface?.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
                surfaceView.terminalSurface?.forceRefresh(reason: "surface.reloadConfig")
                return true
            }
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
        case GHOSTTY_ACTION_OPEN_URL:
            let openUrl = action.action.open_url
            guard let cstr = openUrl.url else { return false }
            let urlString = String(
                data: Data(bytes: cstr, count: Int(openUrl.len)),
                encoding: .utf8
            ) ?? ""
            #if DEBUG
            cmuxDebugLog("link.openURL raw=\(urlString)")
            #endif

            // Try file-path resolution before URL classification.
            // Ghostty's link detection can match file paths that contain
            // slashes or dots (e.g. "docs/spec.md." or "/tmp/spec.md.") as URLs.
            // Attempt to resolve the raw string as a local file first
            // (with trailing-punctuation trimming via cmuxResolveQuicklookPath).
            // If the file exists and cmux can handle it, route through the
            // file viewer instead of the browser.
            let trimmedUrlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            var normalizedOpenURLString = urlString
            if !trimmedUrlString.isEmpty {
                let filePathResolution: (routed: Bool, fallbackPath: String?) = performOnMain {
                    guard let termSurface = surfaceView.terminalSurface,
                          let workspace = termSurface.owningWorkspace(),
                          !workspace.isRemoteTerminalSurface(termSurface.id) else {
                        return (false, nil)
                    }
                    let cwd = CommandClickFileOpenRouter.resolveWorkingDirectory(
                        workspace: workspace,
                        surfaceId: termSurface.id
                    )
                    guard let resolvedPath = cmuxResolveTerminalOpenURLFilePath(trimmedUrlString, cwd: cwd) else {
                        return (false, nil)
                    }
                    guard CommandClickFileOpenRouter.shouldRouteInCmux(path: resolvedPath) else {
                        return (false, resolvedPath)
                    }
                    #if DEBUG
                    cmuxDebugLog("link.openURL resolvedAsFilePath=\(resolvedPath)")
                    #endif
                    let fileURL = URL(fileURLWithPath: resolvedPath)
                    CommandClickFileOpenRouter.deferredOpenFileInCmux(
                        workspace: workspace,
                        preferredWorkspaceId: workspace.id,
                        surfaceId: termSurface.id,
                        filePath: resolvedPath
                    ) {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return (true, resolvedPath)
                }
                if let fallbackPath = filePathResolution.fallbackPath {
                    normalizedOpenURLString = fallbackPath
                }
                if filePathResolution.routed {
                    return true
                }
            }

            guard let target = resolveTerminalOpenURLTarget(normalizedOpenURLString) else {
                #if DEBUG
                cmuxDebugLog("link.openURL resolve failed, returning false")
                #endif
                return false
            }
            // Route local file URLs into cmux when the file-routing toggle is on.
            // URL fragments/queries are stripped (the panel only needs the file
            // path), so links emitted by tools like Claude Code (`foo.md#L42`)
            // still route into the viewer. Anything else (toggle off, hosted
            // file URL, remote workspace, unreadable file, split creation
            // failure) falls through to the existing NSWorkspace path below so
            // URL semantics are preserved.
            let fileURLHost = target.url.host
            if target.url.isFileURL,
               fileURLHost == nil || fileURLHost?.isEmpty == true || fileURLHost == "localhost" {
                let fileURL = target.url
                let routed: Bool = performOnMain {
                    guard let termSurface = surfaceView.terminalSurface,
                          let workspace = termSurface.owningWorkspace(),
                          !workspace.isRemoteTerminalSurface(termSurface.id),
                          CommandClickFileOpenRouter.shouldRouteInCmux(path: fileURL.path) else {
                        return false
                    }
                    CommandClickFileOpenRouter.deferredOpenFileInCmux(
                        workspace: workspace,
                        preferredWorkspaceId: workspace.id,
                        surfaceId: termSurface.id,
                        filePath: fileURL.path
                    ) {
                        NSWorkspace.shared.open(fileURL)
                    }
                    return true
                }
                if routed {
                    return true
                }
                // Fall through to the existing NSWorkspace path below.
            }

            if !BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowser() {
                #if DEBUG
                cmuxDebugLog("link.openURL cmuxBrowser=disabled, opening externally url=\(target.url)")
                #endif
                return performOnMain {
                    NSWorkspace.shared.open(target.url)
                }
            }
            switch target {
            case let .external(url):
                #if DEBUG
                cmuxDebugLog("link.openURL target=external, opening externally url=\(url)")
                #endif
                return performOnMain {
                    NSWorkspace.shared.open(url)
                }
            case let .embeddedBrowser(url):
                if BrowserLinkOpenSettings.shouldOpenExternally(url) {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but shouldOpenExternally=true url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }
                guard let host = BrowserInsecureHTTPSettings.normalizeHost(url.host ?? "") else {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but normalizeHost=nil host=\(url.host ?? "nil") url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }

                // If a host whitelist is configured and this host isn't in it, open externally.
                if !BrowserLinkOpenSettings.hostMatchesWhitelist(host) {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but hostWhitelist miss host=\(host) url=\(url)")
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }
                let sourceWorkspaceId = callbackTabId ?? surfaceView.tabId
                let sourcePanelId = callbackSurfaceId ?? surfaceView.terminalSurface?.id
                guard let sourceWorkspaceId,
                      let sourcePanelId else {
                    #if DEBUG
                    cmuxDebugLog("link.openURL target=embedded but tabId/surfaceId=nil")
                    #endif
                    return false
                }
                #if DEBUG
                cmuxDebugLog(
                    "link.openURL target=embedded, opening in browser pane " +
                    "host=\(host) url=\(url) tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId)"
                )
                #endif
                let canAttemptEmbeddedOpen = performOnMain {
                    BrowserAvailabilitySettings.isEnabled() &&
                    AppDelegate.shared?.workspaceContainingPanel(
                        panelId: sourcePanelId,
                        preferredWorkspaceId: sourceWorkspaceId
                    ) != nil
                }
                guard canAttemptEmbeddedOpen else {
                    #if DEBUG
                    cmuxDebugLog(
                        "link.openURL embedded preflight failed, opening externally " +
                        "tabId=\(sourceWorkspaceId) surfaceId=\(sourcePanelId) url=\(url)"
                    )
                    #endif
                    return performOnMain {
                        NSWorkspace.shared.open(url)
                    }
                }

                // Browser split creation changes focus, which unfocuses the source terminal and
                // calls back into Ghostty. Defer that work until this open_url callback returns.
                // From here cmux owns the open attempt and the deferred path falls back externally.
                Task { @MainActor [url, sourceWorkspaceId, sourcePanelId, host] in
                    let didOpen = Self.openEmbeddedBrowserLink(
                        url: url,
                        sourceWorkspaceId: sourceWorkspaceId,
                        sourcePanelId: sourcePanelId,
                        host: host
                    )
                    guard didOpen else {
                        #if DEBUG
                        cmuxDebugLog("link.openURL deferred open failed url=\(url)")
                        #endif
                        NSSound.beep()
                        return
                    }
                }
                return true
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        let snapshot = WindowAppearanceSnapshot.currentFromUserDefaults(app: self)
        let plan = snapshot.backdropPlan()
        _ = WindowBackdropController.apply(plan: plan, to: window)
        if backgroundLogEnabled {
            logBackground(
                "applied window backdrop phase=\(plan.hostingPhase.rawValue) opacity=\(String(format: "%.3f", defaultBackgroundOpacity)) blur=\(defaultBackgroundBlur)"
            )
        }
    }

    func applyWindowBlurIfNeeded(_ window: NSWindow) {
        guard let app = self.app else { return }
        // ghostty_set_window_background_blur reads background-blur and
        // background-opacity from the app config internally and calls
        // CGSSetWindowBackgroundBlurRadius, a compositor-level setter that is
        // idempotent.  It is a no-op when opacity >= 1.0 or blur is disabled,
        // so we can call it unconditionally whenever the window is transparent.
        ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
    }

    private func activeMainWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if let raw = keyWindow?.identifier?.rawValue,
           raw == "cmux.main" || raw.hasPrefix("cmux.main.") {
            return keyWindow
        }
        return NSApp.windows.first(where: { window in
            guard let raw = window.identifier?.rawValue else { return false }
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        })
    }

    func logBackground(_ message: String) {
        let timestamp = Self.backgroundLogTimestampFormatter.string(from: Date())
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - backgroundLogStartUptime) * 1000
        let frame60 = Int((CACurrentMediaTime() * 60.0).rounded(.down))
        let frame120 = Int((CACurrentMediaTime() * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"
        backgroundLogLock.lock()
        defer { backgroundLogLock.unlock() }
        backgroundLogSequence &+= 1
        let sequence = backgroundLogSequence
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: data)
            }
        }
    }
}
