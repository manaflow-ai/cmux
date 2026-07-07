import Foundation
import CmuxAppKitSupportUI
import CmuxTerminal
import CmuxFoundation
import CmuxPanes
import CmuxTerminalCore
import CmuxSettings
import CmuxWorkspaces
import CmuxTestSupport
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
import IOSurface
import UniformTypeIdentifiers

enum GhosttyStartupAppearancePreviewProfile: String, CaseIterable, Identifiable {
    case realUserConfig
    case freshInstall
    case userThemePair
    case userSingleTheme
    case userExplicitColors

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realUserConfig:
            return String(
                localized: "debug.startupAppearance.profile.realUserConfig.title",
                defaultValue: "Real User Config"
            )
        case .freshInstall:
            return String(
                localized: "debug.startupAppearance.profile.freshInstall.title",
                defaultValue: "Fresh Install"
            )
        case .userThemePair:
            return String(
                localized: "debug.startupAppearance.profile.userThemePair.title",
                defaultValue: "User Light/Dark Theme"
            )
        case .userSingleTheme:
            return String(
                localized: "debug.startupAppearance.profile.userSingleTheme.title",
                defaultValue: "User Single Theme"
            )
        case .userExplicitColors:
            return String(
                localized: "debug.startupAppearance.profile.userExplicitColors.title",
                defaultValue: "User Explicit Colors"
            )
        }
    }

    var detail: String {
        switch self {
        case .realUserConfig:
            return String(
                localized: "debug.startupAppearance.profile.realUserConfig.detail",
                defaultValue: "Loads your actual Ghostty and cmux config files."
            )
        case .freshInstall:
            return String(
                localized: "debug.startupAppearance.profile.freshInstall.detail",
                defaultValue: "No user theme or terminal colors, so cmux applies its managed default colors."
            )
        case .userThemePair:
            return String(
                localized: "debug.startupAppearance.profile.userThemePair.detail",
                defaultValue: "Simulates a user with an explicit light/dark Ghostty theme."
            )
        case .userSingleTheme:
            return String(
                localized: "debug.startupAppearance.profile.userSingleTheme.detail",
                defaultValue: "Simulates a user with one Ghostty theme applied in both appearances."
            )
        case .userExplicitColors:
            return String(
                localized: "debug.startupAppearance.profile.userExplicitColors.detail",
                defaultValue: "Simulates a user with direct terminal color settings and no theme."
            )
        }
    }

    var loadsRealUserConfig: Bool {
        self == .realUserConfig
    }

    func previewConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference()
    ) -> String? {
        switch self {
        case .realUserConfig:
            return nil
        case .freshInstall:
            return GhosttyConfig.cmuxDefaultThemeConfigContents(
                preferredColorScheme: preferredColorScheme
            )
        case .userThemePair:
            return "theme = light:Catppuccin Latte,dark:Catppuccin Mocha"
        case .userSingleTheme:
            return "theme = Catppuccin Mocha"
        case .userExplicitColors:
            return """
            background = #101820
            foreground = #F4F7F7
            cursor-color = #FEE715
            cursor-text = #101820
            selection-background = #28536B
            selection-foreground = #F4F7F7
            palette = 0=#101820
            palette = 1=#C14953
            palette = 2=#47A025
            palette = 3=#D9A441
            palette = 4=#2E86AB
            palette = 5=#9B5DE5
            palette = 6=#00A6A6
            palette = 7=#D6D6D6
            palette = 8=#5C6672
            palette = 9=#FF6B6B
            palette = 10=#7BD88F
            palette = 11=#FFD166
            palette = 12=#54C6EB
            palette = 13=#C77DFF
            palette = 14=#4ECDC4
            palette = 15=#FFFFFF
            """
        }
    }
}

enum GhosttyStartupAppearancePreviewState {
    #if DEBUG
    // The selected debug preview profile. Backed by the CmuxTerminalCore seam
    // (TerminalStartupAppearancePreviewOverride) so GhosttyConfig's loader, now
    // package-bound, never reaches back up into this app-target settings type.
    // The app is the sole writer of the override.
    private nonisolated(unsafe) static var storedProfile: GhosttyStartupAppearancePreviewProfile = .realUserConfig

    static var profile: GhosttyStartupAppearancePreviewProfile {
        get { storedProfile }
        set {
            storedProfile = newValue
            TerminalStartupAppearancePreviewOverride.installed = TerminalStartupAppearancePreviewOverride(
                loadsRealUserConfig: newValue.loadsRealUserConfig,
                previewConfigContents: { colorScheme in
                    newValue.previewConfigContents(preferredColorScheme: colorScheme)
                }
            )
        }
    }
    #else
    static var profile: GhosttyStartupAppearancePreviewProfile = .realUserConfig
    #endif
}

// Window-background policy (cmuxShouldApplyWindowGlass /
// cmuxShouldUseTransparentBackgroundWindow / cmuxShouldUseClearWindowBackground
// / cmuxTransparentWindowBaseColor) and the compositor-blur CGS shims
// (cmuxResetCompositorBackgroundBlur) moved to CmuxWorkspaceWindow as
// WindowBackgroundPolicy + CompositorBlurController. The transitional
// process-wide instances live in WindowBackgroundComposition (app target).

private func cmuxRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyApp.runtimeReadClipboardCallback(userdata, location, state)
}

// GhosttyPasteboardHelper moved to CmuxTerminalServices as
// TerminalPasteboardService (behind the TerminalClipboardReading /
// TerminalClipboardWriting / TerminalImagePasteWriting seams in
// CmuxTerminalCore). The process-wide instance is the transitional
// GhosttyApp.terminalPasteboard composition static below.

/// The app-side conformance injected into ``TerminalLinkRouter``: terminal
/// links validate explicit URL hosts through the same browser rules the
/// embedded browser uses.
struct TerminalBrowserHostNormalizer: BrowserHostNormalizing {
    func normalizedHost(_ rawHost: String) -> String? {
        BrowserInsecureHTTPSettings.normalizeHost(rawHost)
    }
}

func resolveTerminalOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
    TerminalLinkRouter(hostNormalizer: TerminalBrowserHostNormalizer())
        .resolveOpenURLTarget(rawValue)
}

private var terminalKeyboardCopyModeIndicatorText: String {
    String(localized: "ghostty.copy-mode.indicator", defaultValue: "vim")
}

private var terminalKeyTableIndicatorDefaultText: String {
    String(localized: "ghostty.key-table.indicator", defaultValue: "key table")
}

private var terminalKeyTableIndicatorAccessibilityLabel: String {
    String(localized: "ghostty.key-table.icon.accessibility", defaultValue: "Key table")
}

private func terminalKeyTableIndicatorText(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "", "set":
        return terminalKeyTableIndicatorDefaultText
    case "vi", "vim":
        return terminalKeyboardCopyModeIndicatorText
    default:
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? terminalKeyTableIndicatorDefaultText : normalized
    }
}

func terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    CmuxTerminalCore.terminalKeyboardCopyModeShouldBypassForShortcut(
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags)
    )
}

func terminalKeyboardCopyModeAction(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeAction? {
    CmuxTerminalCore.terminalKeyboardCopyModeAction(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags),
        hasSelection: hasSelection,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

func terminalKeyboardCopyModeResolve(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    state: inout TerminalKeyboardCopyModeInputState,
    asciiCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
) -> TerminalKeyboardCopyModeResolution {
    CmuxTerminalCore.terminalKeyboardCopyModeResolve(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifiers: TerminalKeyboardCopyModeModifiers(modifierFlags: modifierFlags),
        hasSelection: hasSelection,
        state: &state,
        asciiCharacterProvider: { keyCode in
            asciiCharacterProvider(keyCode, [])
        }
    )
}

// GhosttySurfaceCallbackContext moved to CmuxTerminalCore behind the
// TerminalSurfaceControlling/TerminalSurfaceHosting seams; the conformances
// and concrete-typed convenience accessors live here.
// TerminalSurface's TerminalSurfaceControlling conformance lives in CmuxTerminal.

extension GhosttyNSView: TerminalSurfaceHosting {
    var hostedTabId: UUID? { tabId }
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { terminalSurface }
}

extension GhosttySurfaceCallbackContext {
    var terminalSurface: TerminalSurface? { surfaceController as? TerminalSurface }
    var surfaceView: GhosttyNSView? { surfaceHost as? GhosttyNSView }
}

// TerminalSurface's TerminalSurfacing conformance lives in CmuxTerminal.

// The surface model drives its views through the CmuxTerminal hosting seams;
// the concrete view classes conform here.
extension GhosttyNSView: TerminalSurfaceNativeViewing {}
extension GhosttySurfaceScrollView: TerminalSurfacePaneHosting {}

extension TerminalSurface {
    /// Concrete-typed convenience over ``TerminalSurface/paneHost`` for app
    /// callers. The pane host is always the app's `GhosttySurfaceScrollView`:
    /// `TerminalSurfaceViewFactory` is the only `TerminalSurfaceViewProviding`
    /// the app ever injects.
    var hostedView: GhosttySurfaceScrollView {
        guard let hosted = paneHost as? GhosttySurfaceScrollView else {
            preconditionFailure("TerminalSurface.paneHost is always GhosttySurfaceScrollView in the app")
        }
        return hosted
    }
}

// The engine's Metal layer reports vended drawables through this seam
// instead of holding the view type directly.
extension GhosttyNSView: TerminalRenderedFrameReceiving {}

extension TerminalSurfaceRegistry {
    /// Concrete-typed convenience over ``surface(id:)`` for app callers.
    func terminalSurface(id: UUID) -> TerminalSurface? {
        surface(id: id) as? TerminalSurface
    }

    /// Concrete-typed convenience over ``allSurfaces()`` for app callers.
    func allTerminalSurfaces() -> [TerminalSurface] {
        allSurfaces().compactMap { $0 as? TerminalSurface }
    }
}

// TerminalSurfaceRuntimeTeardownCoordinator moved to CmuxTerminal
// (Lifecycle/); the process-wide instance is the transitional
// GhosttyApp.terminalSurfaceRuntimeTeardown composition static below.

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    enum ScrollbarVisibility: String {
        case system
        case never
    }

    static let shared = GhosttyApp()

    // MARK: Transitional terminal engine/services composition
    //
    // CmuxTerminalEngine and CmuxTerminalServices ship singleton-free; cmux
    // constructs exactly one instance of each capability here. These statics
    // are the documented transitional accessors for god-file callers
    // (GhosttyTerminalView.swift, AppDelegate, Workspace, TerminalController,
    // TextBoxInput, MainWindowFocusController, MobileTerminalRenderObserver)
    // that cannot take constructor injection until their own decomposition
    // slices land. They dissolve into composition-root injection when
    // GhosttyAppService replaces this type.

    /// The process-wide terminal surface registry (was
    /// `TerminalSurfaceRegistry.shared`). The app delegate attaches itself as
    /// the `MainWindowRouteRetiring` collaborator at launch, inverting the
    /// registry's legacy `AppDelegate.shared` reach-up.
    static let terminalSurfaceRegistry = TerminalSurfaceRegistry()

    /// Gates rendered-frame notifications (was the
    /// `GhosttyRenderedFrameNotificationDemand` namespace enum).
    static let renderedFrameNotificationDemand = RenderDemandCounter()

    /// Gates tick notifications (was the `GhosttyTickNotificationDemand`
    /// namespace enum).
    static let tickNotificationDemand = RenderDemandCounter()

    /// The process-wide pasteboard service (was the `GhosttyPasteboardHelper`
    /// namespace enum).
    static let terminalPasteboard = TerminalPasteboardService()

    /// The process-wide serialized native-surface free queue (was the
    /// `TerminalSurfaceRuntimeTeardownCoordinator.shared` actor singleton).
    static let terminalSurfaceRuntimeTeardown = TerminalSurfaceRuntimeTeardownCoordinator()

    /// The process-wide paced native-surface creation queue for session restore.
    @MainActor
    static let terminalSurfaceRestoreSpawnScheduler = TerminalSurfaceRestoreSpawnScheduler()
    /// Snapshotted once per app session so all workspaces use consistent values.
    static let terminalSessionPortBase: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portBaseKey)
        return val > 0 ? val : AutomationSettings.defaultPortBase
    }()
    static let terminalSessionPortRangeSize: Int = {
        let val = UserDefaults.standard.integer(forKey: AutomationSettings.portRangeKey)
        return val > 0 ? val : AutomationSettings.defaultPortRange
    }()

    /// The injected collaborators for every `TerminalSurface` (transitional:
    /// dissolves into composition-root injection when `GhosttyAppService`
    /// replaces this type).
    @MainActor
    static let terminalSurfaceRuntimeDependencies = TerminalSurfaceRuntimeDependencies(
        registry: GhosttyApp.terminalSurfaceRegistry,
        engine: GhosttyApp.shared,
        viewProvider: TerminalSurfaceViewFactory(),
        spawnPolicy: TerminalSurfaceSpawnPolicyBridge(),
        byteTee: TerminalMobileByteTeeBridge(),
        rendererRealization: RendererRealizationController.shared,
        hibernationRecorder: TerminalAgentHibernationRecorder(),
        runtimeTeardown: GhosttyApp.terminalSurfaceRuntimeTeardown,
        restoreSpawnScheduler: GhosttyApp.terminalSurfaceRestoreSpawnScheduler,
        runtimeFilesystem: .live(),
        sessionPortBase: GhosttyApp.terminalSessionPortBase,
        sessionPortRangeSize: GhosttyApp.terminalSessionPortRangeSize,
        scrollbackReplayEnvironmentKey: SessionScrollbackReplayStore.environmentKey, globalFontMagnificationPercent: { GlobalFontMagnification.storedPercent }
    )

    private static let releaseBundleIdentifier = "com.cmuxterm.app"
    /// Shared config-file discovery seam. Resolves Ghostty config scan paths,
    /// scans them for font/appearance directives, and decides legacy/CJK/theme
    /// overrides. The C-API config-load methods below call it to decide *what*
    /// to load; it performs no `ghostty_config_t` mutation itself.
    private static let configDiscovery = GhosttyConfigDiscovery()
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
        // The legacy release closure decremented on every call; a retention
        // releases exactly once, which only removes a latent double-release
        // hazard (no caller releases twice on purpose).
        let retention = tickNotificationDemand.retain()
        return { retention.release() }
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

    fileprivate static func runtimeReadClipboardCallback(
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
                    // Remote tmux mirror panes need tmux to bracket the paste
                    // because the local manual-I/O surface cannot know the
                    // remote pane's bracketed-paste mode.
                    let handledByMirror = !text.isEmpty && MainActor.assumeIsolated {
                        AppDelegate.shared?.remoteTmuxController.pasteIntoMirror(
                            surfaceId: callbackContext.surfaceId,
                            text: text
                        ) ?? false
                    }
                    let completionText = handledByMirror ? "" : text
                    completionText.withCString { ptr in
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

            guard let pasteboard = GhosttyApp.terminalPasteboard.pasteboard(for: location) else {
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

                let handledByCustomUpload = Self.handleCustomPasteUploadIfMatched(
                    plan: plan,
                    operation: operation,
                    callbackContext: callbackContext,
                    completeClipboardRequest: completeClipboardRequest
                )

                if !handledByCustomUpload {
                    TerminalImageTransferPlanner.execute(
                        plan: plan,
                        operation: operation,
                        uploadWorkspaceRemote: { fileURLs, operation, finish in
                            guard let workspace = MainActor.assumeIsolated({
                                callbackContext.terminalSurface?.owningWorkspace()
                            }) else {
                                finish(.failure(NSError(domain: "cmux.remote.paste", code: 3)))
                                GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                                return
                            }
                            workspace.uploadDroppedFilesForRemoteTerminal(
                                fileURLs,
                                operation: operation,
                                completion: { result in
                                    finish(result)
                                    GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                                }
                            )
                        },
                        uploadDetectedSSH: { session, fileURLs, operation, finish in
                            session.uploadDroppedFiles(
                                fileURLs,
                                operation: operation,
                                completion: { result in
                                    finish(result)
                                    GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
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
    private let backgroundLogWriter = BackgroundLogWriter(
        fileURL: GhosttyApp.resolveBackgroundLogURL(),
        startUptime: ProcessInfo.processInfo.systemUptime
    )
    private var appObservers: [NSObjectProtocol] = []
    private var bellAudioSound: NSSound?
    private var backgroundEventCounter: UInt64 = 0
    private var defaultBackgroundUpdateScope: GhosttyDefaultBackgroundUpdateScope = .unscoped
    private var defaultBackgroundScopeSource: String = "initialize"
    private var lastAppearanceColorScheme: GhosttyConfig.ColorSchemePreference?
    @MainActor private lazy var defaultBackgroundNotificationDispatcher: GhosttyDefaultBackgroundNotificationDispatcher =
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
                        GhosttyApp.terminalPasteboard.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyApp.terminalPasteboard.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            let callbackSurfaceId = callbackContext.surfaceId
            let callbackTabId = callbackContext.tabId

#if DEBUG
            TerminalChildExitProbe().write(
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
                if let registeredSurface = GhosttyApp.terminalSurfaceRegistry.surface(id: callbackSurfaceId),
                   registeredSurface !== callbackSurface {
#if DEBUG
                    cmuxDebugLog(
                        "surface.closeCallback.ignore surface=\(callbackSurfaceId.uuidString.prefix(5)) reason=staleCallbackSurface"
                    )
#endif
                    return
                }
                if app.closeWindowDockRuntimeSurface(surfaceId: callbackSurfaceId, force: !needsConfirmClose) { return }
                // Close requests must be resolved by the callback's workspace/surface IDs only.
                // If the mapping is already gone (duplicate/stale callback), ignore it.
                if let callbackTabId, let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager {
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
            loadGlobalFontMagnificationConfig(fallbackConfig)
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
        guard let contents = TerminalManagedGhosttySettings.ghosttyConfigContents(emitsCopyOnSelectFalse: false) else { return }
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

    /// Loads the user's resolved Ghostty config with cmux's managed default appearance
    /// applied first, as the base: only an explicit user `theme` suppresses it, while
    /// individual color keys override just those colors (issue #7161).
    private func loadRealUserGhosttyConfig(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        themeColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        let appearanceSummary = Self.userAppearanceConfigSummary()
        if appearanceSummary.shouldApplyDefaultAppearance {
            loadCmuxDefaultAppearanceConfig(config, preferredColorScheme: preferredColorScheme)
        }
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        loadCmuxAppSupportGhosttyConfigIfNeeded(config)
        ghostty_config_load_recursive_files(config)
        loadConditionalThemeOverrideIfNeeded(config, preferredColorScheme: themeColorScheme)
        // Ghostty's own default-file load also reads the native legacy app-support
        // `config` that cmux's scan-path policy treats as stale when `config.ghostty`
        // is non-empty. When the user set no appearance directives at all, re-assert
        // the managed default so that skipped legacy file's colors cannot override it.
        if appearanceSummary.shouldApplyDefaultAppearance, !appearanceSummary.hasExplicitTerminalColorDirective {
            loadCmuxDefaultAppearanceConfig(config, preferredColorScheme: preferredColorScheme)
        }
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
            loadRealUserGhosttyConfig(config, preferredColorScheme: preferredColorScheme, themeColorScheme: themeColorScheme)
        } else {
            loadStartupPreviewProfile(startupPreviewProfile, into: config, preferredColorScheme: preferredColorScheme)
        }
        #else
        loadRealUserGhosttyConfig(config, preferredColorScheme: preferredColorScheme, themeColorScheme: themeColorScheme)
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
        loadGlobalFontMagnificationConfig(config)
        loadCmuxOwnedGhosttyKeybindOverrides(config)
        loadNoActiveDisplayVsyncFallbackIfNeeded(config)

        ghostty_config_finalize(config)
        return renderingModeChanged
    }
    func loadGlobalFontMagnificationConfig(_ config: ghostty_config_t) {
        guard !GlobalFontMagnification.isDefault else { return }
        var fontSize: Float32 = 0
        let key = "font-size"
        guard ghostty_config_get(config, &fontSize, key, UInt(key.lengthOfBytes(using: .utf8))),
              fontSize.isFinite, fontSize > 0 else { return }
        let scaledFontSize = max(1, CGFloat(fontSize) * GlobalFontMagnification.scale)
        loadInlineGhosttyConfig(
            "font-size = \(Double(scaledFontSize))", into: config,
            prefix: "cmux-global-font-magnification",
            logLabel: "global font magnification"
        )
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
            \(Self.numberedWorkspaceGhosttyUnbinds)
            """,
            into: config,
            prefix: "cmux-owned-keybind-overrides",
            logLabel: "cmux-owned keybind overrides"
        )
    }

    /// Unbinds Ghostty's built-in `super+1…8 = goto_tab` / `super+9 = last_tab`
    /// fallbacks so the numbered "Select Workspace 1…9" shortcut is owned solely
    /// by `KeyboardShortcutSettings`.
    ///
    /// Without this, a `⌘1–9` remapped away in Settings still falls through to the
    /// focused terminal and Ghostty performs `goto_tab`, so the rebind looks
    /// hardcoded (https://github.com/manaflow-ai/cmux/issues/5189). Ghostty registers
    /// each digit under both its Unicode form (`super+1`) and its physical-key form
    /// (`super+digit_1`), so both are unbound here.
    private static let numberedWorkspaceGhosttyUnbinds: String = {
        (1...9).flatMap { digit in
            ["keybind = super+\(digit)=unbind", "keybind = super+digit_\(digit)=unbind"]
        }.joined(separator: "\n")
    }()

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

    /// Returns (range, font) pairs for CJK font fallback based on the system's
    /// preferred languages. Forwards to ``GhosttyConfigDiscovery``.
    static func cjkFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [(String, String)]? {
        configDiscovery.cjkFontMappings(preferredLanguages: preferredLanguages)
    }

    /// Returns only the CJK mappings cmux should auto-inject. Forwards to
    /// ``GhosttyConfigDiscovery``.
    static func autoInjectedCJKFontMappings(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String]? = nil,
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> [(String, String)]? {
        configDiscovery.autoInjectedCJKFontMappings(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        )
    }

    /// Whether the user's Ghostty config files already contain a CJK
    /// `font-codepoint-map` entry. Forwards to ``GhosttyConfigDiscovery``.
    static func userConfigContainsCJKCodepointMap(
        configPaths: [String]? = nil
    ) -> Bool {
        configDiscovery.userConfigContainsCJKCodepointMap(configPaths: configPaths)
    }

    static func userConfigHasExplicitFontFamilyFallbackChain(
        configPaths: [String]? = nil
    ) -> Bool {
        configDiscovery.userConfigHasExplicitFontFamilyFallbackChain(configPaths: configPaths)
    }

    static func shouldInjectCJKFontFallback(
        preferredLanguages: [String] = Locale.preferredLanguages,
        configPaths: [String]? = nil,
        rangeCoverageProbe: ((String, String) -> Bool)? = nil
    ) -> Bool {
        configDiscovery.shouldInjectCJKFontFallback(
            preferredLanguages: preferredLanguages,
            configPaths: configPaths,
            rangeCoverageProbe: rangeCoverageProbe
        )
    }

    static func shouldApplyManagedDefaultAppearance(
        configPaths: [String]? = nil
    ) -> Bool {
        configDiscovery.shouldApplyManagedDefaultAppearance(configPaths: configPaths)
    }

    static func userAppearanceConfigSummary(configPaths: [String]? = nil) -> GhosttyConfig.UserAppearanceConfigSummary {
        GhosttyConfig.userAppearanceConfigSummary(configPaths: configPaths ?? loadedGhosttyConfigScanPaths())
    }

    static func conditionalThemeOverrideConfigContents(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        configPaths: [String]? = nil
    ) -> String? {
        configDiscovery.conditionalThemeOverrideConfigContents(
            preferredColorScheme: preferredColorScheme,
            configPaths: configPaths
        )
    }

    /// Resolves auto-injected CJK families through the regular-weight descriptor
    /// path. Forwards to ``GhosttyConfigDiscovery``.
    static func resolvedInjectedCJKFontName(
        named name: String,
        size: CGFloat = 12
    ) -> String {
        configDiscovery.resolvedInjectedCJKFontName(named: name, size: size)
    }

    /// Mirror Ghostty's family-name CoreText discovery path. Forwards to
    /// ``GhosttyConfigDiscovery``.
    static func discoveredCTFont(
        named name: String,
        size: CGFloat = 12,
        weightTrait: CGFloat? = nil
    ) -> CTFont? {
        configDiscovery.discoveredFont(named: name, size: size, weightTrait: weightTrait)
    }

    /// Returns the top-level Ghostty config paths cmux may load before recursive
    /// `config-file` processing. Forwards to ``GhosttyConfigDiscovery``.
    static func loadedGhosttyConfigScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        configDiscovery.loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    static func loadedCJKScanPaths(
        currentBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> [String] {
        configDiscovery.loadedCJKScanPaths(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    static func shouldLoadLegacyGhosttyConfig(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        configDiscovery.shouldLoadLegacyGhosttyConfig(
            newConfigFileSize: newConfigFileSize,
            legacyConfigFileSize: legacyConfigFileSize
        )
    }

    static func shouldIncludeLegacyGhosttyConfigInScanPaths(
        newConfigFileSize: Int?,
        legacyConfigFileSize: Int?
    ) -> Bool {
        configDiscovery.shouldIncludeLegacyGhosttyConfigInScanPaths(
            newConfigFileSize: newConfigFileSize,
            legacyConfigFileSize: legacyConfigFileSize
        )
    }

    static func shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
        appSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    ) -> Bool {
        configDiscovery.shouldIgnoreNativeLegacyBaselineForUnparsedAppearance(
            appSupportDirectory: appSupportDirectory
        )
    }

    static func cmuxAppSupportConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        configDiscovery.cmuxAppSupportConfigURLs(
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
        if Self.tickNotificationDemand.isActive {
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
        let resolved = GhosttyConfig.load(preferredColorScheme: preferredColorScheme, useCache: false, globalFontMagnificationPercent: GlobalFontMagnification.storedPercent)
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
        let signal: @MainActor () -> Void = { [self] in
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
            MainActor.assumeIsolated { signal() }
        } else {
            Task { @MainActor in
                signal()
            }
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
            TerminalChildExitProbe().write(
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
                if let callbackSurfaceId, app.closeWindowDockRuntimeSurface(surfaceId: callbackSurfaceId, force: true) { return }
                if let callbackTabId, let callbackSurfaceId,
                   let manager = app.tabManagerFor(tabId: callbackTabId) ?? app.tabManager {
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
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                surfaceView.updateGhosttyMouseShape(shape)
            }
            return true
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
               let sourceSurface = surfaceView.terminalSurface {
                let change = GhosttyTitleChange(tabId: tabId, surfaceId: sourceSurface.id, title: title)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: sourceSurface,
                        userInfo: change.userInfo
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManagerFor(tabId: tabId)?.updateReportedSurfaceDirectory(
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
            // (with trailing-punctuation trimming via TerminalPathResolver's quicklook resolution).
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
                    guard let resolvedPath = TerminalPathResolver().resolveOpenURLFilePath(trimmedUrlString, cwd: cwd) else {
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
                cmuxDebugLog("link.openURL resolve ignored, consumed invalid token")
                #endif
                return true
            }
            #if DEBUG
            if UITestCaptureSink().appendLineIfConfigured(
                envKey: "CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH",
                line: target.url.absoluteString
            ) {
                return true
            }
            #endif
            // Route local file paths into cmux when the file-routing toggle is on.
            // Explicit URL schemes (including file://) stay on the URL route so
            // the OS owns non-web schemes, while bare paths like `foo.md#L42`
            // still route into the viewer when eligible.
            if TerminalOpenURLFileRoutingPolicy().shouldAttemptCmuxFileRouting(
                rawOpenURLValue: trimmedUrlString,
                target: target
            ) {
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

    @MainActor
    private func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        let windowChrome = AppWindowChromeComposition()
        let snapshot = windowChrome.appearanceSnapshotFromUserDefaults(app: self)
        let plan = snapshot.backdropPlan(
            glassEffectAvailable: windowChrome.glassEffect.isAvailable,
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        _ = windowChrome.backdropController.apply(plan: plan, to: window)
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
        // Skip all work (timing capture, string formatting, and disk I/O) unless
        // background logging is explicitly enabled via env/defaults. Without this
        // guard, direct callers wrote to /tmp/cmux-bg.log on every theme/OSC color
        // event even in normal runs.
        guard backgroundLogEnabled else { return }
        // The writer captures cheap timing values here and performs all string
        // formatting + the file append on a dedicated serial queue against a single
        // long-lived handle, so emitting a line never blocks the calling thread —
        // frequently the main thread, inside SwiftUI appearance updates. See
        // https://github.com/manaflow-ai/cmux/issues/5833.
        backgroundLogWriter.log(message, isMainThread: Thread.isMainThread)
    }
}

// MARK: - Debug Render Instrumentation

// GhosttyMetalLayer and the render/tick demand gates moved to
// CmuxTerminalEngine (RenderDemandCounter behind the RenderDemandGating seam);
// TerminalSurfaceRegistry moved to CmuxTerminalEngine behind
// TerminalSurfaceRegistering, its AppDelegate reach-up inverted via
// MainWindowRouteRetiring. The process-wide instances live in the
// transitional GhosttyApp composition statics below.

/// Core Image filter that cuts a pane-local terminal fill out of the shared window backdrop.
private final class TerminalSharedBackdropCutoutFilter: CIFilter {
    private static let filterInputKeys = [kCIInputImageKey, kCIInputBackgroundImageKey]
    private static let filterOutputKeys = [kCIOutputImageKey]

    /// The mask image supplied by AppKit for the cutout view.
    @objc dynamic var inputImage: CIImage?

    /// The already-rendered shared backdrop behind the terminal surface.
    @objc dynamic var inputBackgroundImage: CIImage?

    /// Input keys advertised to AppKit's Core Image compositing pipeline.
    override var inputKeys: [String] {
        Self.filterInputKeys
    }

    /// Output keys advertised to AppKit's Core Image compositing pipeline.
    override var outputKeys: [String] {
        Self.filterOutputKeys
    }

    /// The backdrop image with the cutout mask removed.
    override var outputImage: CIImage? {
        guard let inputImage, let inputBackgroundImage else { return nil }
        return CIBlendKernel.destinationOut.apply(
            foreground: inputImage,
            background: inputBackgroundImage
        )
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

// TerminalSurfaceFocusPlacement moved to CmuxTerminalCore (SurfaceRegistry/).

private func recordAgentHibernationTerminalInput(workspaceId: UUID, panelId: UUID) {
    guard AgentHibernationTrackingGate.isEnabled() else { return }
    let recordedAt = Date()
    Task { @MainActor in
        AgentHibernationController.shared.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId,
            recordedAt: recordedAt
        )
    }
}

// TerminalSurface and its SearchState moved to the CmuxTerminal package
// (Surface/TerminalSurface*.swift), with the legacy GhosttyApp /
// TerminalController / MobileTerminalByteTee / RendererRealizationController /
// AgentHibernationController reach-ups inverted through
// TerminalSurfaceRuntimeDependencies (see TerminalSurfaceRuntimeWiring.swift).

extension TerminalSurface {
    @MainActor
    func owningWorkspace() -> Workspace? {
        AppDelegate.shared?.workspaceFor(tabId: tabId)
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_FOCUS_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxFocusDebug")
    }()
    internal enum DropPlan: Equatable {
        case insertText(String)
        case uploadFiles([URL])
        case reject
    }

    private static let dropTypes: Set<NSPasteboard.PasteboardType> = PasteboardFileURLReader.fileURLPasteboardTypes.union([
        .string,
        .URL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.heif.identifier)
    ])
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")

    private enum WordPathResolutionSource: String {
        case quicklook
        case snapshot
    }

    private struct WordPathResolution {
        let path: String
        let source: WordPathResolutionSource
        let rawToken: String
    }

    private func makeWordPathResolution(
        path: String,
        source: WordPathResolutionSource,
        rawToken: String
    ) -> WordPathResolution {
        WordPathResolution(
            path: path,
            source: source,
            rawToken: rawToken
        )
    }

    fileprivate static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        AppDelegate.shared?.focusLog.append(message)
        #if DEBUG
        NSLog("[FOCUSDBG] %@", message)
        #endif
    }

    weak var terminalSurface: TerminalSurface?
    var scrollbar: GhosttyScrollbar?
    /// Pending scrollbar value written from the action callback thread;
    /// read and cleared on the main thread by `flushPendingScrollbar()`.
    /// Access is guarded by `_scrollbarLock` because the action callback
    /// fires on Ghostty's I/O thread while the flush runs on main.
    private var _pendingScrollbar: GhosttyScrollbar?
    private var _scrollbarFlushScheduled = false
    private let _scrollbarLock = NSLock()
    private var _renderedFrameFlushScheduled = false
    private let _renderedFrameLock = NSLock()
    var cellSize: CGSize = .zero
    private var lastKnownMousePointInView: NSPoint?
    private var ghosttyMouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT

    static func retainRenderedFrameNotifications() -> () -> Void {
        // See GhosttyApp.retainTickNotifications() on the idempotent release.
        let retention = GhosttyApp.renderedFrameNotificationDemand.retain()
        return { retention.release() }
    }

    private static func ghosttyMouseCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            return .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
             GHOSTTY_MOUSE_SHAPE_CELL:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING,
             GHOSTTY_MOUSE_SHAPE_MOVE:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_COPY:
            return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS:
            return .dragLink
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
            return .resizeUpDown
        default:
            return .arrow
        }
    }

    fileprivate func updateGhosttyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard ghosttyMouseShape != shape else { return }
        ghosttyMouseShape = shape
        window?.invalidateCursorRects(for: self)
    }

    /// Coalesce high-frequency scrollbar updates into a single main-thread
    /// dispatch.  The action callback (which may fire thousands of times per
    /// second during bulk output like `seq 1 100000`) stores the latest value
    /// and schedules exactly one async flush.
    func enqueueScrollbarUpdate(_ newValue: GhosttyScrollbar) {
        _scrollbarLock.lock()
        defer { _scrollbarLock.unlock() }
        // Store the latest value (always overwrites — only the newest matters).
        _pendingScrollbar = newValue
        let needsSchedule = !_scrollbarFlushScheduled
        if needsSchedule { _scrollbarFlushScheduled = true }

        // If a flush is already scheduled, skip the dispatch — the scheduled
        // block will pick up the latest value.
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingScrollbar()
        }
    }

    private func flushPendingScrollbar() {
        _scrollbarLock.lock()
        _scrollbarFlushScheduled = false
        let pending = _pendingScrollbar
        _pendingScrollbar = nil
        _scrollbarLock.unlock()

        guard let pending else { return }
        let wasPendingViewportJumpSync = keyboardCopyModePendingViewportJumpSync
        scrollbar = pending
        finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: pending)
        if !wasPendingViewportJumpSync,
           keyboardCopyModeVisualLineActive,
           let surface {
            reselectKeyboardCopyModeVisualLineSelection(surface: surface)
        }
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: self,
            userInfo: [GhosttyNotificationKey.scrollbar: pending]
        )
    }

    private func flushPendingScrollbarIfAvailable() -> Bool {
        _scrollbarLock.lock()
        let hasPending = _pendingScrollbar != nil
        _scrollbarLock.unlock()

        guard hasPending else { return false }
        flushPendingScrollbar()
        return true
    }

    func enqueueRenderedFrameUpdate() {
        guard GhosttyApp.renderedFrameNotificationDemand.isActive else { return }

        _renderedFrameLock.lock()
        let needsSchedule = !_renderedFrameFlushScheduled
        if needsSchedule {
            _renderedFrameFlushScheduled = true
        }
        _renderedFrameLock.unlock()

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushRenderedFrameUpdate()
        }
    }

    private func flushRenderedFrameUpdate() {
        _renderedFrameLock.lock()
        _renderedFrameFlushScheduled = false
        _renderedFrameLock.unlock()

        guard GhosttyApp.renderedFrameNotificationDemand.isActive else { return }
        NotificationCenter.default.post(
            name: .ghosttyDidRenderFrame,
            object: self
        )
    }

    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var appliedColorScheme: ghostty_color_scheme_e?
    private var lastLoggedSurfaceBackgroundSignature: String?
    private var lastLoggedWindowBackgroundSignature: String?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
    fileprivate private(set) var keyboardCopyModeActive = false
    private var wordPathHoverActive = false
    private var keyboardCopyModeConsumedKeyUps: Set<UInt16> = []
    private var imeConsumedKeyUps: Set<UInt16> = []
    private var keyboardCopyModeInputState = TerminalKeyboardCopyModeInputState()
    private var keyboardCopyModeCursor: TerminalKeyboardCopyModeCursor?
    private var keyboardCopyModePendingViewportJumpSync = false
    private var keyboardCopyModePendingViewportJumpScrollbarOffset: UInt64?
    private var keyboardCopyModePendingViewportJumpGeneration = 0
    private var keyboardCopyModePendingViewportJumpFallbackLineDelta: Int?
    private var keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
    private var keyboardCopyModePendingViewportJumpVisualLineReselect = false
    private var keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint = false
    private var keyboardCopyModePendingViewportJumpVisualLineSelection: TerminalKeyboardCopyModeVisualLineSelection?
    private var keyboardCopyModeViewportJumpSyncExpirationTimer: Timer?
    /// Tracks whether the user has explicitly entered visual selection mode (v).
    /// Separate from Ghostty's `has_selection` because non-visual copy mode keeps
    /// the cursor in AppKit overlay state until visual selection starts.
    private var keyboardCopyModeVisualActive = false
    private var keyboardCopyModeVisualLineSelection: TerminalKeyboardCopyModeVisualLineSelection?
    private var keyboardCopyModeVisualLineRuntimeSelectionSynced = false
    private var keyboardCopyModeVisualLineActive: Bool {
        keyboardCopyModeVisualLineSelection != nil
    }
    private static let keyboardCopyModeVisualLineFallbackMaxBytes: UInt = 2 * 1024 * 1024
    private let keyboardCopyModeCursorOverlayView = GhosttyFlashOverlayView(frame: .zero)
    // internal (not fileprivate): witnesses for TerminalSurfaceNativeViewing
    // must match the conforming class's access level.
    var isKeyboardCopyModeActive: Bool { keyboardCopyModeActive }
    var currentKeyStateIndicatorText: String? {
        if let name = keyTables.last {
            return terminalKeyTableIndicatorText(name)
        }

        if keyboardCopyModeActive {
            return terminalKeyboardCopyModeIndicatorText
        }

        return nil
    }
#if DEBUG
    private static let keyLatencyProbeEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    @MainActor static var debugGhosttySurfaceKeyEventObserver: ((ghostty_input_key_s) -> Void)?
    @MainActor static var debugTextInputEventHandler: ((GhosttyNSView, NSEvent) -> Bool)?
#endif
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var lastScrollEventTime: CFTimeInterval = 0
    private let scrollSpeedAccumulator = TerminalScrollSpeedAccumulator()
    private var visibleInUI: Bool = true
    private var pendingSurfaceSize: CGSize?
    private var deferredSurfaceSizeRetryQueued = false, needsSurfaceSizeRetryAfterMetalLayerRealizes = false
    private var deferredSurfaceSizeNonMetalRetryCount = 0
    private var lastDrawableSize: CGSize = .zero
    private var isFindEscapeSuppressionArmed = false
    private var hasPendingLeftMouseRelease = false
#if DEBUG
    private var lastSizeSkipSignature: String?
#endif
    private static let maxDeferredSurfaceSizeNonMetalRetryCount = 8

    private var hasUsableFocusGeometry: Bool { bounds.width > 1 && bounds.height > 1 }

    static func shouldRequestFirstResponderForMouseFocus(
        focusFollowsMouseEnabled: Bool,
        pressedMouseButtons: Int,
        appIsActive: Bool,
        windowIsKey: Bool,
        alreadyFirstResponder: Bool,
        visibleInUI: Bool,
        hasUsableGeometry: Bool,
        hiddenInHierarchy: Bool
    ) -> Bool {
        guard focusFollowsMouseEnabled else { return false }
        guard pressedMouseButtons == 0 else { return false }
        guard appIsActive, windowIsKey else { return false }
        guard !alreadyFirstResponder else { return false }
        guard visibleInUI, hasUsableGeometry, !hiddenInHierarchy else { return false }
        return true
    }

    // Visibility is used for focus gating. Explicit portal visibility transitions
    // also drive Ghostty occlusion so hidden workspace/split surfaces pause and
    // queue a redraw when they become visible again.
    fileprivate var isVisibleInUI: Bool { visibleInUI }
    fileprivate func setVisibleInUI(_ visible: Bool) {
        visibleInUI = visible
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = GhosttyMetalLayer()
        metalLayer.setFrameReceiver(self)
        metalLayer.setRenderDemand(GhosttyApp.renderedFrameNotificationDemand)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        Task { @MainActor [weak self] in self?.reconcileSurfaceSizeAfterMetalLayerAttachIfNeeded() }
        // framebufferOnly=false lets the macOS compositor read the drawable
        // when blending translucent or blurred window layers.  This matches
        // standalone Ghostty's SurfaceView and is required for background-opacity
        // and background-blur to render correctly.
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        // GhosttyMetalLayer provides render stats and opt-in frame notifications for
        // input sequencing that needs to wait for terminal redraws.
        wantsLayer = true
        layer?.masksToBounds = true
        setupKeyboardCopyModeCursorOverlay()
        installEventMonitor()
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    private func setupKeyboardCopyModeCursorOverlay() {
        keyboardCopyModeCursorOverlayView.wantsLayer = true
        keyboardCopyModeCursorOverlayView.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.45)
            .cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.70)
            .cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderWidth = 1
        keyboardCopyModeCursorOverlayView.isHidden = true
        addSubview(keyboardCopyModeCursorOverlayView, positioned: .above, relativeTo: nil)
    }

    func applySurfaceBackground() {
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: GhosttyApp.shared.usesHostLayerBackground
        )
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        let usesBonsplitPaneBackdrop = Workspace.usesBonsplitPaneTerminalBackdrop(
            renderingMode: renderingMode,
            sharesWindowBackdrop: sharesWindowBackdrop
        )
        let fillPlan = TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: backgroundColor,
            defaultBackgroundColor: GhosttyApp.shared.defaultBackgroundColor,
            backgroundOpacity: GhosttyApp.shared.defaultBackgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            usesBonsplitPaneBackdrop: usesBonsplitPaneBackdrop
        )
        let color = fillPlan.hostLayerColor
        if let layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // GhosttySurfaceScrollView owns the panel background fill. Keeping this layer clear
            // avoids stacking multiple identical translucent backgrounds (which looks opaque).
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            CATransaction.commit()
        }
        terminalSurface?.hostedView.setBackgroundColor(
            color,
            clearsSharedWindowBackdrop: fillPlan.clearsSharedWindowBackdrop
        )
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(fillPlan.usesHostLayerFill ? color.hexString() : "transparent-host"):\(String(format: "%.3f", color.alphaComponent)):\(fillPlan.logBackdropLabel)"
            if signature != lastLoggedSurfaceBackgroundSignature {
                lastLoggedSurfaceBackgroundSignature = signature
                let hasOverride = backgroundColor != nil
                let overrideHex = backgroundColor?.hexString() ?? "nil"
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                GhosttyApp.shared.logBackground(
                    "surface background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(fillPlan.logSource(hasSurfaceOverride: hasOverride)) override=\(overrideHex) default=\(defaultHex) sharedWindowBackdrop=\(sharesWindowBackdrop ? 1 : 0) bonsplitPaneBackdrop=\(usesBonsplitPaneBackdrop ? 1 : 0) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent))"
                )
            }
        }
    }

    // Theme/background application is window-local. During cross-window workspace
    // switches (e.g. jump-to-unread), the global active tab manager can lag behind.
    // Prefer the owning window's selected workspace when available.
    static func shouldApplyWindowBackground(
        surfaceTabId: UUID?,
        owningManagerExists: Bool,
        owningSelectedTabId: UUID?,
        activeSelectedTabId: UUID?
    ) -> Bool {
        guard let surfaceTabId else { return true }
        if owningManagerExists {
            guard let owningSelectedTabId else { return true }
            return owningSelectedTabId == surfaceTabId
        }
        if let activeSelectedTabId {
            return activeSelectedTabId == surfaceTabId
        }
        return true
    }

    @MainActor
    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        let appDelegate = AppDelegate.shared
        let owningManager = tabId.flatMap { appDelegate?.tabManagerFor(tabId: $0) }
        let owningSelectedTabId = owningManager?.selectedTabId
        let activeSelectedTabId = owningManager == nil ? appDelegate?.tabManager?.selectedTabId : nil
        guard Self.shouldApplyWindowBackground(
            surfaceTabId: tabId,
            owningManagerExists: owningManager != nil,
            owningSelectedTabId: owningSelectedTabId,
            activeSelectedTabId: activeSelectedTabId
        ) else {
            return
        }
        applySurfaceBackground()
        let windowChrome = AppWindowChromeComposition()
        let windowRoot = windowChrome
            .appearanceSnapshotFromUserDefaults(app: GhosttyApp.shared)
            .windowRootBackdropResolution(surfaceBackgroundColor: backgroundColor)
        let plan = windowRoot.snapshot.backdropPlan(
            glassEffectAvailable: windowChrome.glassEffect.isAvailable,
            windowBackgroundPolicy: windowChrome.windowBackgroundPolicy
        )
        let color = windowRoot.snapshot.compositedTerminalBackgroundColor
        _ = windowChrome.backdropController.apply(plan: plan, to: window)
        if GhosttyApp.shared.backgroundLogEnabled {
            let signature = "\(plan.hostingPhase.rawValue):\(color.hexString()):\(String(format: "%.3f", color.alphaComponent)):\(GhosttyApp.shared.defaultBackgroundBlur)"
            if signature != lastLoggedWindowBackgroundSignature {
                lastLoggedWindowBackgroundSignature = signature
                let defaultHex = GhosttyApp.shared.defaultBackgroundColor.hexString()
                GhosttyApp.shared.logBackground(
                    "window background applied tab=\(tabId?.uuidString ?? "unknown") surface=\(terminalSurface?.id.uuidString ?? "unknown") source=\(windowRoot.source) override=\(windowRoot.overrideHex) default=\(defaultHex) phase=\(plan.hostingPhase.rawValue) transparent=\(plan.usesTransparentWindow) color=\(color.hexString()) opacity=\(String(format: "%.3f", color.alphaComponent)) blur=\(GhosttyApp.shared.defaultBackgroundBlur)"
                )
            }
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

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        let isSameSurface = terminalSurface === surface
        let isAlreadyAttached = surface.isAttached(to: self)
        if !isSameSurface {
            appliedColorScheme = nil
            // Reset any OSC 22 mouse shape carried over from the previous
            // surface; the newly-bound surface re-emits its own shape via
            // GHOSTTY_ACTION_MOUSE_SHAPE if it has one.
            updateGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        }
        terminalSurface = surface
        tabId = surface.tabId
        if !isAlreadyAttached {
            surface.attachToView(self)
        } else {
            surface.reconcileAttachedWindowIfNeeded(for: self)
        }
        surface.setKeyboardCopyModeActive(keyboardCopyModeActive)
        if !isAlreadyAttached {
            updateSurfaceSize()
        }
        applySurfaceBackground()
        applySurfaceColorScheme(force: !isSameSurface || !isAlreadyAttached)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        // Balance the cursor stack if the view is removed while hover is active
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        cmuxDebugLog(
            "surface.view.windowMove surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) bounds=\(String(format: "%.1fx%.1f", Double(bounds.width), Double(bounds.height))) " +
            "pending=\(String(format: "%.1fx%.1f", Double(pendingSurfaceSize?.width ?? 0), Double(pendingSurfaceSize?.height ?? 0)))"
        )
#endif
        guard let window else { return }

        // Reconcile the already-started runtime with the real window backing context.
        terminalSurface?.attachToView(self)
        if let terminalSurface {
            NotificationCenter.default.post(
                name: .terminalSurfaceHostedViewDidMoveToWindow,
                object: terminalSurface,
                userInfo: [
                    "surfaceId": terminalSurface.id,
                    "workspaceId": terminalSurface.tabId
                ]
            )
        }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            self?.windowDidChangeScreen(notification)
        }

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        // Recompute from current bounds after layout. Pending size is only a fallback
        // when we don't have usable bounds (e.g. detached/off-window transitions).
        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateSurfaceSize()
        applySurfaceBackground()
        applySurfaceColorScheme(force: true)
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidMoveToWindow"
        )
        applyWindowBackgroundIfActive()
        invalidateTextInputCoordinates()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if GhosttyApp.shared.backgroundLogEnabled {
            let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            GhosttyApp.shared.logBackground(
                "surface appearance changed tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil")"
            )
        }
        applySurfaceColorScheme()
        GhosttyApp.shared.synchronizeThemeWithAppearance(
            effectiveAppearance,
            source: "surface.viewDidChangeEffectiveAppearance"
        )
    }

    fileprivate func updateOcclusionState() {
        // Intentionally no-op: we don't drive libghostty occlusion from AppKit occlusion state.
        // This avoids transient clears during reparenting and keeps rendering logic minimal.
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
        invalidateTextInputCoordinates()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
        syncKeyboardCopyModeCursorOverlay()
        invalidateTextInputCoordinates()
        terminalSurface?.hostedView.scheduleSuppressedFirstResponderFocusReapplyIfReady(
            reason: "becomeFirstResponder.hiddenOrTiny.layout"
        )
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateSurfaceSize(bypassLiveResizeCoalescing: true)
        invalidateTextInputCoordinates()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.ghosttyMouseCursor(for: ghosttyMouseShape))
    }

    override var isOpaque: Bool { false }

    private func resolvedSurfaceSize(preferred size: CGSize?) -> CGSize {
        if let size,
           size.width > 0,
           size.height > 0 {
            return size
        }
        let currentBounds = bounds.size
        if currentBounds.width > 0, currentBounds.height > 0 {
            return currentBounds
        }
        if let pending = pendingSurfaceSize,
           pending.width > 0,
           pending.height > 0 {
            return pending
        }
        return currentBounds
    }

    private static func hasTabDragPasteboardTypes() -> Bool {
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(tabTransferPasteboardType) || types.contains(sidebarTabReorderPasteboardType)
    }

    private static func isDragResizeEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private static func shouldDeferSurfaceResizeForActiveDrag() -> Bool {
        // The drag pasteboard can retain tab-transfer UTIs briefly after a split command
        // or other layout churn. Only defer terminal resizes while an actual drag event
        // is in flight; otherwise pre-existing panes can stay stuck at their old size.
        // Interactive geometry resize already has an explicit fast path for sidebar and
        // split-divider drags. Do not let stale drag-pasteboard state suppress those updates.
        if TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive {
            return false
        }
        guard hasTabDragPasteboardTypes() else { return false }
        return isDragResizeEvent(NSApp.currentEvent?.type)
    }

    private func activeSurfaceResizeDeferralReason() -> String? {
        if isWindowLiveResizeActive { return nil }
        return Self.shouldDeferSurfaceResizeForActiveDrag() ? "tabDrag" : nil
    }

    private var isWindowLiveResizeActive: Bool {
        inLiveResize || window?.inLiveResize == true
    }

    @discardableResult private func scheduleDeferredSurfaceSizeRetryIfNeeded() -> Bool {
        guard window != nil, !deferredSurfaceSizeRetryQueued else { return false }
        deferredSurfaceSizeRetryQueued = true
        Task { @MainActor [weak self] in guard let self else { return }; self.deferredSurfaceSizeRetryQueued = false; _ = self.updateSurfaceSize() }
        return true
    }

    @MainActor fileprivate func reconcileSurfaceSizeAfterMetalLayerAttachIfNeeded() { guard needsSurfaceSizeRetryAfterMetalLayerRealizes else { return }; deferredSurfaceSizeNonMetalRetryCount = 0; _ = updateSurfaceSize() }

    @discardableResult
    private func updateSurfaceSize(
        size: CGSize? = nil,
        bypassLiveResizeCoalescing: Bool = false
    ) -> Bool {
        guard let terminalSurface = terminalSurface else { return false }
        let size = resolvedSurfaceSize(preferred: size)
        guard size.width > 0 && size.height > 0 else {
#if DEBUG
            let signature = "nonPositive-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=nonPositive size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
        if pendingSurfaceSize != size { deferredSurfaceSizeNonMetalRetryCount = 0 }
        pendingSurfaceSize = size
        if let deferralReason = activeSurfaceResizeDeferralReason() {
            scheduleDeferredSurfaceSizeRetryIfNeeded()
#if DEBUG
            let signature = "\(deferralReason)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(deferralReason) " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "inWindow=\(window != nil ? 1 : 0)"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        guard let window else {
#if DEBUG
            let signature = "noWindow-\(Int(size.width))x\(Int(size.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=noWindow " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }

        // Derive pixel size from the window's backing scale, NOT from
        // convertToBacking: that conversion folds in ancestor transforms
        // (the canvas layout's NSScrollView magnification), which would
        // re-typeset the terminal at a shrunken pixel grid while zooming and
        // render duplicated rows. Terminals keep their logical pixel density
        // and scale visually under magnification; in split mode the two
        // formulas are identical.
        let backingSize = CGSize(
            width: size.width * max(1.0, window.backingScaleFactor),
            height: size.height * max(1.0, window.backingScaleFactor)
        )
        guard backingSize.width > 0, backingSize.height > 0 else {
#if DEBUG
            let signature = "zeroBacking-\(Int(backingSize.width))x\(Int(backingSize.height))"
            if lastSizeSkipSignature != signature {
                cmuxDebugLog(
                    "surface.size.defer surface=\(terminalSurface.id.uuidString.prefix(5)) reason=zeroBacking " +
                    "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                    "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
                )
                lastSizeSkipSignature = signature
            }
#endif
            return false
        }
#if DEBUG
        if lastSizeSkipSignature != nil {
            cmuxDebugLog(
                "surface.size.resume surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "size=\(String(format: "%.1fx%.1f", size.width, size.height)) " +
                "backing=\(String(format: "%.1fx%.1f", backingSize.width, backingSize.height))"
            )
            lastSizeSkipSignature = nil
        }
#endif
        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, window.backingScaleFactor)
        let drawablePixelSize = CGSize(
            width: floor(max(0, backingSize.width)),
            height: floor(max(0, backingSize.height))
        )
        var didChange = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer, !nearlyEqual(layer.contentsScale, layerScale) {
            didChange = true
        }
        layer?.contentsScale = layerScale
        layer?.masksToBounds = true
        if let metalLayer = layer as? CAMetalLayer {
            deferredSurfaceSizeNonMetalRetryCount = 0
            needsSurfaceSizeRetryAfterMetalLayerRealizes = false
            if drawablePixelSize != lastDrawableSize || metalLayer.drawableSize != drawablePixelSize {
                if metalLayer.drawableSize != drawablePixelSize {
                    didChange = true
                    metalLayer.drawableSize = drawablePixelSize
                }
                lastDrawableSize = drawablePixelSize
            }
        } else if deferredSurfaceSizeNonMetalRetryCount < Self.maxDeferredSurfaceSizeNonMetalRetryCount,
                  scheduleDeferredSurfaceSizeRetryIfNeeded() {
            needsSurfaceSizeRetryAfterMetalLayerRealizes = true
            deferredSurfaceSizeNonMetalRetryCount += 1
        }
        CATransaction.commit()

        let surfaceSizeChanged = terminalSurface.updateSize(
            width: size.width,
            height: size.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale,
            backingSize: backingSize,
            coalescePixelOnlyResize: isWindowLiveResizeActive && !bypassLiveResizeCoalescing
        )
        return didChange || surfaceSizeChanged
    }

    @discardableResult
    fileprivate func pushTargetSurfaceSize(_ size: CGSize) -> Bool {
        updateSurfaceSize(size: size)
    }

#if DEBUG
    fileprivate func debugPendingSurfaceSize() -> CGSize? { pendingSurfaceSize }
    func debugLastDrawableSizeForTesting() -> CGSize { lastDrawableSize }
    func debugDeferredSurfaceSizeRetryQueuedForTesting() -> Bool { deferredSurfaceSizeRetryQueued }
    @discardableResult func debugUpdateSurfaceSizeForTesting(_ size: CGSize) -> Bool { updateSurfaceSize(size: size) }
#endif

    /// Force a full size reconciliation for the current bounds.
    /// Keep the drawable-size cache intact so redundant refresh paths do not
    /// reallocate Metal drawables when the pixel size is unchanged.
    @discardableResult
    func forceRefreshSurface() -> Bool {
        updateSurfaceSize()
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    func expectedPixelSize(for pointsSize: CGSize) -> CGSize {
        // Mirrors the surface-size derivation: window backing scale only, so
        // ancestor magnification (canvas zoom) never re-typesets the grid.
        let scale = max(1.0, window?.backingScaleFactor ?? layer?.contentsScale ?? 1.0)
        return CGSize(width: pointsSize.width * scale, height: pointsSize.height * scale)
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    fileprivate func applySurfaceColorScheme(
        force: Bool = false,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
        guard let surface else { return }
        let bestMatch = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let preferredColorScheme = preferredColorScheme
            ?? GhosttyApp.shared.effectiveTerminalColorSchemePreference
        let scheme = GhosttyApp.ghosttyRuntimeColorScheme(for: preferredColorScheme)
        if !force, appliedColorScheme == scheme {
            if GhosttyApp.shared.backgroundLogEnabled {
                let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
                GhosttyApp.shared.logBackground(
                    "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=false"
                )
            }
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
        appliedColorScheme = scheme
        if GhosttyApp.shared.backgroundLogEnabled {
            let schemeLabel = scheme == GHOSTTY_COLOR_SCHEME_DARK ? "dark" : "light"
            GhosttyApp.shared.logBackground(
                "surface color scheme tab=\(tabId?.uuidString ?? "nil") surface=\(terminalSurface?.id.uuidString ?? "nil") bestMatch=\(bestMatch?.rawValue ?? "nil") preferred=\(schemeLabel) scheme=\(schemeLabel) force=\(force) applied=true"
            )
        }
    }

    @discardableResult
    private func ensureSurfaceReadyForInput() -> ghostty_surface_t? {
        if let surface = surface {
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToViewForInputDemand(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        return surface
    }

    private func requestInputRecoveryAfterSurfaceMiss(reason: String) {
        terminalSurface?.requestInputDemandSurfaceStartIfNeeded()
#if DEBUG
        cmuxDebugLog(
            "focus.input_recovery surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) inWindow=\(window != nil ? 1 : 0)"
        )
#endif
    }

    @discardableResult
    func prepareSurfaceForPaste(reason: String) -> Bool {
        guard ensureSurfaceReadyForInput() != nil else {
            requestInputRecoveryAfterSurfaceMiss(reason: reason)
            return false
        }
        return true
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    @discardableResult
    func toggleKeyboardCopyMode() -> Bool {
        guard surface != nil else { return false }
        setKeyboardCopyModeActive(!keyboardCopyModeActive)
        if !keyboardCopyModeActive, let surface {
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
        }
        return true
    }

    private func setKeyboardCopyModeActive(_ active: Bool) {
        keyboardCopyModeInputState.reset()
        keyboardCopyModeVisualActive = false
        keyboardCopyModeVisualLineSelection = nil
        keyboardCopyModeVisualLineRuntimeSelectionSynced = false
        keyboardCopyModePendingViewportJumpGeneration += 1
        clearKeyboardCopyModeViewportJumpCursorSync()
        keyboardCopyModeActive = active
        if active, let surface {
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
            keyboardCopyModeCursor = keyboardCopyModeInitialCursor(surface: surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        } else {
            keyboardCopyModeCursor = nil
            syncKeyboardCopyModeCursorOverlay()
        }
        terminalSurface?.setKeyboardCopyModeActive(active)
    }

    @discardableResult
    private func performBindingAction(_ action: String, repeatCount: Int) -> Bool {
        var performed = true
        for _ in 0 ..< terminalKeyboardCopyModeClampCount(repeatCount) { performed = performBindingAction(action) && performed }
        return performed
    }

    private func performKeyboardCopyModeLineScroll(_ lineDelta: Int) -> Bool {
        var remaining = lineDelta
        while remaining != 0 {
            let chunk = max(Int(Int16.min), min(Int(Int16.max), remaining)); remaining -= chunk
            guard performBindingAction("scroll_page_lines:\(chunk)") else { return false }
        }
        return true
    }
    private func currentKeyboardCopyModeViewportRow(surface: ghostty_surface_t) -> Int {
        let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
            ?? max(Int(ghostty_surface_size(surface).rows), 1)
        let fallback = rows - 1
        return max(0, min(rows - 1, keyboardCopyModeCursor?.row ?? fallback))
    }

    private struct KeyboardCopyModeGridMetrics {
        let rows: Int
        let columns: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let xInset: CGFloat
        let yInset: CGFloat
        let viewHeight: CGFloat

        func topOriginRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            CGRect(
                x: xInset + (CGFloat(cursor.column) * cellWidth),
                y: yInset + (CGFloat(cursor.row) * cellHeight),
                width: cellWidth,
                height: cellHeight
            )
        }

        func appKitRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
            let topOrigin = topOriginRect(for: cursor)
            let rawY = viewHeight - topOrigin.maxY
            let maxY = max(viewHeight - topOrigin.height, 0)
            return CGRect(
                x: topOrigin.minX,
                y: min(max(rawY, 0), maxY),
                width: topOrigin.width,
                height: topOrigin.height
            )
        }
    }

    private func keyboardCopyModeGridMetrics(surface: ghostty_surface_t) -> KeyboardCopyModeGridMetrics? {
        let size = ghostty_surface_size(surface)
        let backingRows = max(Int(size.rows), 1)
        let columns = max(Int(size.columns), 1)
        let backingScaleFactor = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        let resolvedCellWidth = cellSize.width > 0
            ? cellSize.width
            : CGFloat(size.cell_width_px) / backingScaleFactor
        let resolvedCellHeight = cellSize.height > 0
            ? cellSize.height
            : CGFloat(size.cell_height_px) / backingScaleFactor
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: backingRows,
            viewHeight: Double(bounds.height),
            cellHeight: Double(resolvedCellHeight)
        )
        let terminalWidth = CGFloat(columns) * resolvedCellWidth
        let terminalHeight = CGFloat(rows) * resolvedCellHeight
        return KeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: resolvedCellWidth,
            cellHeight: resolvedCellHeight,
            xInset: max(0, (bounds.width - terminalWidth) / 2),
            yInset: max(0, (bounds.height - terminalHeight) / 2),
            viewHeight: bounds.height
        )
    }

    private func keyboardCopyModeInitialCursor(surface: ghostty_surface_t) -> TerminalKeyboardCopyModeCursor {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            return TerminalKeyboardCopyModeCursor(row: 0, column: 0)
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let row = terminalKeyboardCopyModeInitialViewportRow(
            rows: metrics.rows,
            imePointY: y,
            imeCellHeight: Double(metrics.cellHeight),
            topPadding: Double(metrics.yInset)
        )
        let column = terminalKeyboardCopyModeInitialViewportColumn(
            columns: metrics.columns,
            imePointX: x,
            imeCellWidth: Double(metrics.cellWidth),
            leftPadding: Double(metrics.xInset)
        )
        return TerminalKeyboardCopyModeCursor(row: row, column: column)
    }

    private func syncKeyboardCopyModeCursorOverlay(surface explicitSurface: ghostty_surface_t? = nil) {
        guard keyboardCopyModeActive,
              !keyboardCopyModeVisualActive,
              let surface = explicitSurface ?? self.surface,
              let cursor = keyboardCopyModeCursor,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            keyboardCopyModeCursorOverlayView.isHidden = true
            return
        }

        let clampedCursor = cursor.clamped(rows: metrics.rows, columns: metrics.columns)
        if clampedCursor != cursor {
            keyboardCopyModeCursor = clampedCursor
        }

        keyboardCopyModeCursorOverlayView.frame = metrics.appKitRect(for: clampedCursor)
        keyboardCopyModeCursorOverlayView.isHidden = false
    }

    private func moveKeyboardCopyModeCursor(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        let scrollDelta = cursor.move(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
        if scrollDelta != 0 { _ = performKeyboardCopyModeLineScroll(scrollDelta) }
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func clampKeyboardCopyModeCursor(surface: ghostty_surface_t) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func clearKeyboardCopyModeViewportJumpCursorSync() {
        keyboardCopyModePendingViewportJumpSync = false; keyboardCopyModePendingViewportJumpVisualLineReselect = false; keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint = false
        keyboardCopyModePendingViewportJumpScrollbarOffset = nil; keyboardCopyModePendingViewportJumpFallbackLineDelta = nil
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0; keyboardCopyModePendingViewportJumpVisualLineSelection = nil
        keyboardCopyModeViewportJumpSyncExpirationTimer?.invalidate(); keyboardCopyModeViewportJumpSyncExpirationTimer = nil
    }

    private func beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: Int? = nil, visualLineReselect: Bool = false, updatesVisualLineEndpoint: Bool = false) {
        let flushedScrollbar = flushPendingScrollbarIfAvailable()
        if keyboardCopyModePendingViewportJumpSync, !flushedScrollbar {
            if keyboardCopyModePendingViewportJumpVisualLineReselect, visualLineReselect {
                keyboardCopyModePendingViewportJumpFallbackLineDelta =
                    (keyboardCopyModePendingViewportJumpFallbackLineDelta ?? 0) + (keyboardCopyModeBoundedFallbackLineDelta(fallbackLineDelta) ?? 0)
                keyboardCopyModePendingViewportJumpVisualLineSelection = keyboardCopyModeVisualLineSelection; keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint = keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint || updatesVisualLineEndpoint
                scheduleKeyboardCopyModeViewportJumpCursorSyncExpiration(); return
            }
            if !keyboardCopyModePendingViewportJumpVisualLineReselect, !visualLineReselect {
                scheduleKeyboardCopyModeViewportJumpCursorSyncExpiration(); return
            }
        }
        keyboardCopyModePendingViewportJumpGeneration += 1
        keyboardCopyModePendingViewportJumpSync = true
        keyboardCopyModePendingViewportJumpScrollbarOffset = scrollbar?.offset
        keyboardCopyModePendingViewportJumpFallbackLineDelta = keyboardCopyModeBoundedFallbackLineDelta(fallbackLineDelta)
        keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = 0
        keyboardCopyModePendingViewportJumpVisualLineReselect = visualLineReselect
        keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint = updatesVisualLineEndpoint
        keyboardCopyModePendingViewportJumpVisualLineSelection = visualLineReselect ? keyboardCopyModeVisualLineSelection : nil
        scheduleKeyboardCopyModeViewportJumpCursorSyncExpiration()
    }

    private func keyboardCopyModeBoundedFallbackLineDelta(_ lineDelta: Int?) -> Int? {
        guard let lineDelta, let scrollbar else { return lineDelta }
        guard lineDelta != 0 else { return 0 }

        if lineDelta > 0 {
            let maxOffset = scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0
            let available = maxOffset > scrollbar.offset ? maxOffset - scrollbar.offset : 0
            return min(lineDelta, Int(clamping: available))
        }

        return max(lineDelta, -Int(clamping: scrollbar.offset))
    }

    private func scheduleKeyboardCopyModeViewportJumpCursorSyncExpiration() {
        let generation = keyboardCopyModePendingViewportJumpGeneration
        keyboardCopyModeViewportJumpSyncExpirationTimer?.invalidate()
        // Ghostty can omit scrollbar packets for no-op copy-mode jumps; expire stale sync state through a cancellable deadline.
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            self?.cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: generation)
        }
        keyboardCopyModeViewportJumpSyncExpirationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: ghostty_surface_t) {
        guard keyboardCopyModePendingViewportJumpSync,
              keyboardCopyModeActive else { return }

        if flushPendingScrollbarIfAvailable() {
            return
        }

        if keyboardCopyModePendingViewportJumpVisualLineReselect {
            if keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint {
                updateKeyboardCopyModeVisualLineEndpointFromCursor(surface: surface)
            }
            keyboardCopyModePendingViewportJumpVisualLineSelection = keyboardCopyModeVisualLineSelection
            reselectKeyboardCopyModeVisualLineSelection(surface: surface)
            return
        }

        if let lineDelta = keyboardCopyModePendingViewportJumpFallbackLineDelta,
           lineDelta != 0,
           keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta == 0 {
            shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: lineDelta, surface: surface)
            keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta = lineDelta
            return
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(generation: Int) {
        guard keyboardCopyModePendingViewportJumpSync,
              generation == keyboardCopyModePendingViewportJumpGeneration else { return }

        clearKeyboardCopyModeViewportJumpCursorSync()
    }

    private func finishKeyboardCopyModeViewportJumpCursorSyncIfNeeded(newScrollbar: GhosttyScrollbar? = nil) {
        guard keyboardCopyModePendingViewportJumpSync else { return }
        guard keyboardCopyModeActive, let surface else { clearKeyboardCopyModeViewportJumpCursorSync(); return }
        let resolvedNewOffset = newScrollbar?.offset ?? scrollbar?.offset
        if keyboardCopyModePendingViewportJumpVisualLineReselect,
           let expectedOffset = keyboardCopyModePendingVisualLineScrollOffset(), let resolvedNewOffset,
           let delta = keyboardCopyModePendingViewportJumpFallbackLineDelta,
           delta != 0 && (delta > 0 ? resolvedNewOffset < expectedOffset : resolvedNewOffset > expectedOffset) { return }
        keyboardCopyModePendingViewportJumpSync = false
        defer { clearKeyboardCopyModeViewportJumpCursorSync() }
        if keyboardCopyModePendingViewportJumpVisualLineReselect {
            if keyboardCopyModePendingViewportJumpUpdatesVisualLineEndpoint, keyboardCopyModePendingViewportJumpVisualLineSelection == keyboardCopyModeVisualLineSelection {
                updateKeyboardCopyModeVisualLineEndpointFromCursor(surface: surface)
            }
            reselectKeyboardCopyModeVisualLineSelection(surface: surface)
            return
        }

        if let previousOffset = keyboardCopyModePendingViewportJumpScrollbarOffset,
           let resolvedNewOffset {
            let lineDelta = keyboardCopyModeViewportLineDelta(
                from: previousOffset,
                to: resolvedNewOffset
            )
            let remainingLineDelta = lineDelta - keyboardCopyModePendingViewportJumpAppliedFallbackLineDelta
            if remainingLineDelta != 0 {
                shiftKeyboardCopyModeCursorForViewportScroll(lineDelta: remainingLineDelta, surface: surface)
                return
            }
        }

        clampKeyboardCopyModeCursor(surface: surface)
    }

    private func keyboardCopyModeViewportLineDelta(from previousOffset: UInt64, to currentOffset: UInt64) -> Int {
        if currentOffset >= previousOffset {
            return Int(clamping: currentOffset - previousOffset)
        }
        return -Int(clamping: previousOffset - currentOffset)
    }

    private func updateKeyboardCopyModeCursorModel(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.moveAfterTerminalSelectionAdjustment(
            direction,
            count: count,
            rows: metrics.rows,
            columns: metrics.columns
        )
        keyboardCopyModeCursor = cursor
    }

    private func shiftKeyboardCopyModeCursorForViewportScroll(
        lineDelta: Int,
        surface: ghostty_surface_t
    ) {
        guard lineDelta != 0,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        cursor.shiftForViewportScroll(lineDelta: lineDelta, rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func adjustKeyboardCopyModeSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        let action = "adjust_selection:\(direction.rawValue)"
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        for _ in 0 ..< clampedCount {
            _ = performBindingAction(action)
            updateKeyboardCopyModeCursorModel(direction, count: 1, surface: surface)
        }
    }

    private func selectKeyboardCopyModeCursorCell(surface: ghostty_surface_t) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }

        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor

        let rect = metrics.topOriginRect(for: cursor)
        let y = min(max(rect.midY, 0), max(bounds.height - 1, 0))
        guard let xRange = terminalKeyboardCopyModeCursorSelectionXRange(
            rectMinX: Double(rect.minX),
            rectMaxX: Double(rect.maxX),
            boundsWidth: Double(bounds.width)
        ) else {
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
            return false
        }
        let mods = GHOSTTY_MODS_NONE

        _ = GhosttyRuntimeCInterop.clearSelection(surface)
        ghostty_surface_mouse_pos(surface, xRange.startX, Double(y), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
            return false
        }
        ghostty_surface_mouse_pos(surface, xRange.endX, Double(y), mods)
        let selectedCursorCell = ghostty_surface_has_selection(surface)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        guard selectedCursorCell else {
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
            return false
        }
        return true
    }

    private func selectKeyboardCopyModeViewportLines(
        surface: ghostty_surface_t,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        let rows = metrics.rows
        let targetRow = max(0, min(rows - 1, startRow))
        let endRow = min(rows - 1, targetRow + clampedCount - 1)
        _ = GhosttyRuntimeCInterop.clearSelection(surface)

        let yMax = max(bounds.height - 1, 0)

        let startRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: targetRow, column: 0)
        ).midY
        let endRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: endRow, column: max(metrics.columns - 1, 0))
        ).midY
        let startY = max(0, min(startRawY, yMax))
        let endY = max(0, min(endRawY, yMax))
        let xMax = max(bounds.width - 1, 0)
        let startX = min(metrics.xInset + 0.5, xMax)
        let endX = min(metrics.xInset + (CGFloat(metrics.columns) * metrics.cellWidth) - 0.5, xMax)

        let mods = GHOSTTY_MODS_NONE
        ghostty_surface_mouse_pos(surface, Double(startX), Double(startY), mods)
        guard ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods) else {
            return false
        }
        defer {
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }
        ghostty_surface_mouse_pos(surface, Double(endX), Double(endY), mods)
        return ghostty_surface_has_selection(surface)
    }
    private func keyboardCopyModePendingVisualLineScrollOffset() -> UInt64? {
        guard keyboardCopyModePendingViewportJumpSync,
              let lineDelta = keyboardCopyModePendingViewportJumpFallbackLineDelta,
              let baseOffset = keyboardCopyModePendingViewportJumpScrollbarOffset else { return nil }
        return TerminalKeyboardCopyModeVisualLineSelection.pendingScrollOffset(
            baseOffset: baseOffset,
            lineDelta: lineDelta,
            totalRows: scrollbar?.total
        )
    }

    private func keyboardCopyModeBoundaryFallbackLineDelta(_ direction: TerminalKeyboardCopyModeSelectionMove, visibleRows: Int) -> Int? {
        guard let scrollbar else { return nil }
        return TerminalKeyboardCopyModeVisualLineSelection.boundaryFallbackLineDelta(
            direction,
            scrollOffset: scrollbar.offset,
            totalRows: scrollbar.total,
            visibleRows: UInt64(max(visibleRows, 1))
        )
    }

    private func updateKeyboardCopyModeVisualLineEndpointFromCursor(surface: ghostty_surface_t) {
        guard var selection = keyboardCopyModeVisualLineSelection,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = cursor
        selection.updateEndpoint(
            from: cursor,
            viewportRows: metrics.rows,
            scrollOffset: scrollbar?.offset ?? 0,
            totalRows: scrollbar?.total
        )
        keyboardCopyModeVisualLineSelection = selection
        _ = syncKeyboardCopyModeVisualLineRuntimeSelection(surface: surface)
    }

    private func clearKeyboardCopyModeVisualLineSelection(surface: ghostty_surface_t) {
        keyboardCopyModeVisualActive = false
        keyboardCopyModeVisualLineSelection = nil
        keyboardCopyModeVisualLineRuntimeSelectionSynced = false
        _ = GhosttyRuntimeCInterop.clearSelection(surface)
    }

    private func syncKeyboardCopyModeVisualLineRuntimeSelection(surface: ghostty_surface_t) -> Bool {
        guard let selection = keyboardCopyModeVisualLineSelection,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return false }
        let scrollOffset = keyboardCopyModePendingVisualLineScrollOffset() ?? scrollbar?.offset ?? 0
        guard let visibleRows = selection.visibleIntersection(scrollOffset: scrollOffset, viewportRows: metrics.rows) else {
            keyboardCopyModeVisualLineRuntimeSelectionSynced = false
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
            return true
        }

        let startRow = Int(clamping: visibleRows.lowerBound - scrollOffset)
        let lineCount = Int(clamping: visibleRows.upperBound - visibleRows.lowerBound + 1)
        let selected = selectKeyboardCopyModeViewportLines(surface: surface, startRow: startRow, lineCount: lineCount)
        keyboardCopyModeVisualLineRuntimeSelectionSynced = selected
        if !selected { _ = GhosttyRuntimeCInterop.clearSelection(surface) }
        return selected
    }

    private func readKeyboardCopyModeVisualLineSelection(surface: ghostty_surface_t) -> String? {
        _ = flushPendingScrollbarIfAvailable()
        guard let selectedRows = keyboardCopyModeVisualLineSelection?.selectedRows,
              let metrics = keyboardCopyModeGridMetrics(surface: surface),
              let readRows = TerminalKeyboardCopyModeVisualLineSelection.boundedReadRows(
                selectedRows: selectedRows,
                columns: metrics.columns,
                maxBytes: Self.keyboardCopyModeVisualLineFallbackMaxBytes
              ) else { return nil }

        let topLeft = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: readRows.lower)
        let bottomRight = ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(clamping: max(metrics.columns - 1, 0)), y: readRows.upper)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard text.text_len <= Self.keyboardCopyModeVisualLineFallbackMaxBytes,
              let byteCount = Int(exactly: text.text_len),
              let rawText = text.text else { return nil }
        let selectedText = String(decoding: Data(bytes: rawText, count: byteCount), as: UTF8.self)
        return selectedText.isEmpty ? nil : selectedText
    }

    private func copyCurrentGhosttySelectionToClipboard(surface: ghostty_surface_t) -> Bool {
        let generalPasteboard = NSPasteboard.general
        let previousChangeCount = generalPasteboard.changeCount
        let copied = performBindingAction("copy_to_clipboard")

        // Ghostty owns clipboard formatting; the raw selection snapshot is only the no-op pasteboard fallback.
        let ghosttyWroteFormattedText = generalPasteboard.changeCount != previousChangeCount
            && generalPasteboard.availableType(from: [.string]) != nil
        if ghosttyWroteFormattedText {
            return true
        }

        guard let selectedText = readSelectionSnapshot(surface: surface)?.string, !selectedText.isEmpty else {
            return copied
        }

        GhosttyApp.terminalPasteboard.writeString(selectedText, to: GHOSTTY_CLIPBOARD_STANDARD)
        return true
    }

    private func copyKeyboardCopyModeSelectionToClipboard(surface: ghostty_surface_t) -> Bool {
        if keyboardCopyModeVisualLineActive {
            guard let selectedText = readKeyboardCopyModeVisualLineSelection(surface: surface) else { return false }
            GhosttyApp.terminalPasteboard.writeString(selectedText, to: GHOSTTY_CLIPBOARD_STANDARD)
            return true
        }

        return copyCurrentGhosttySelectionToClipboard(surface: surface)
    }

    private func hasCopyableTerminalSelection(surface: ghostty_surface_t) -> Bool {
        keyboardCopyModeVisualLineActive || ghostty_surface_has_selection(surface)
    }

    private func copyCurrentViewportLinesToClipboard(
        surface: ghostty_surface_t,
        startRow: Int,
        lineCount: Int
    ) -> Bool {
        guard selectKeyboardCopyModeViewportLines(
            surface: surface,
            startRow: startRow,
            lineCount: lineCount
        ) else {
            return false
        }
        return copyKeyboardCopyModeSelectionToClipboard(surface: surface)
    }

    private func startKeyboardCopyModeLineSelection(surface: ghostty_surface_t, lineCount: Int) {
        let startRow = currentKeyboardCopyModeViewportRow(surface: surface)
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { clearKeyboardCopyModeVisualLineSelection(surface: surface); syncKeyboardCopyModeCursorOverlay(surface: surface); return }
        keyboardCopyModeCursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        if clampedCount > 1 {
            keyboardCopyModeCursor?.row = min(startRow + clampedCount - 1, metrics.rows - 1)
        }
        let scrollOffset = keyboardCopyModePendingVisualLineScrollOffset() ?? scrollbar?.offset ?? 0
        let totalRows = scrollbar?.total
        keyboardCopyModeVisualLineSelection = TerminalKeyboardCopyModeVisualLineSelection(
            anchorScreenRow: TerminalKeyboardCopyModeVisualLineSelection.screenRow(
                forViewportRow: startRow,
                viewportRows: metrics.rows,
                scrollOffset: scrollOffset,
                totalRows: totalRows
            ),
            endpointScreenRow: TerminalKeyboardCopyModeVisualLineSelection.screenRow(
                forViewportRow: keyboardCopyModeCursor?.row ?? startRow,
                viewportRows: metrics.rows,
                scrollOffset: scrollOffset,
                totalRows: totalRows
            )
        )
        guard syncKeyboardCopyModeVisualLineRuntimeSelection(surface: surface) else { clearKeyboardCopyModeVisualLineSelection(surface: surface); syncKeyboardCopyModeCursorOverlay(surface: surface); return }
        keyboardCopyModeVisualActive = true
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func reselectKeyboardCopyModeVisualLineSelection(surface: ghostty_surface_t) {
        guard let selection = keyboardCopyModeVisualLineSelection,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        let cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        keyboardCopyModeCursor = selection.endpointCursor(
            column: cursor.column,
            viewportRows: metrics.rows,
            viewportColumns: metrics.columns,
            scrollOffset: scrollbar?.offset ?? 0
        )
        guard syncKeyboardCopyModeVisualLineRuntimeSelection(surface: surface) else { clearKeyboardCopyModeVisualLineSelection(surface: surface); syncKeyboardCopyModeCursorOverlay(surface: surface); return }
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func adjustKeyboardCopyModeVisualLineSelectionToBoundary(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        surface: ghostty_surface_t
    ) {
        guard let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        var cursor = (keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface))
            .clamped(rows: metrics.rows, columns: metrics.columns)
        switch direction {
        case .home:
            cursor.row = 0
            cursor.column = 0
        case .end:
            cursor.row = metrics.rows - 1
            cursor.column = metrics.columns - 1
        default:
            return
        }
        keyboardCopyModeCursor = cursor
        var updatesEndpointFromCursor = true
        if var selection = keyboardCopyModeVisualLineSelection, selection.moveEndpointToBoundary(direction, totalRows: scrollbar?.total) {
            keyboardCopyModeVisualLineSelection = selection; updatesEndpointFromCursor = false
            guard syncKeyboardCopyModeVisualLineRuntimeSelection(surface: surface) else { clearKeyboardCopyModeVisualLineSelection(surface: surface); syncKeyboardCopyModeCursorOverlay(surface: surface); return }
        }

        beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: keyboardCopyModeBoundaryFallbackLineDelta(direction, visibleRows: metrics.rows), visualLineReselect: true, updatesVisualLineEndpoint: updatesEndpointFromCursor)
        let action = direction == .home ? "scroll_to_top" : "scroll_to_bottom"
        guard performBindingAction(action) else {
            cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                generation: keyboardCopyModePendingViewportJumpGeneration
            )
            if updatesEndpointFromCursor { updateKeyboardCopyModeVisualLineEndpointFromCursor(surface: surface) }
            reselectKeyboardCopyModeVisualLineSelection(surface: surface)
            return
        }
        resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
    }

    private func adjustKeyboardCopyModeVisualLineSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard var selection = keyboardCopyModeVisualLineSelection,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else { return }
        if direction == .home || direction == .end {
            adjustKeyboardCopyModeVisualLineSelectionToBoundary(direction, surface: surface)
            return
        }
        let scrollOffset = keyboardCopyModePendingVisualLineScrollOffset() ?? scrollbar?.offset ?? 0
        let currentCursor = keyboardCopyModeCursor ?? keyboardCopyModeInitialCursor(surface: surface)
        let move = selection.moveEndpoint(
            direction,
            count: count,
            currentColumn: currentCursor.column,
            viewportRows: metrics.rows,
            viewportColumns: metrics.columns,
            scrollOffset: scrollOffset,
            totalRows: scrollbar?.total
        )
        keyboardCopyModeVisualLineSelection = selection
        keyboardCopyModeCursor = move.cursor
        guard syncKeyboardCopyModeVisualLineRuntimeSelection(surface: surface) else { clearKeyboardCopyModeVisualLineSelection(surface: surface); syncKeyboardCopyModeCursorOverlay(surface: surface); return }
        let scrollDelta = move.scrollDelta
        if scrollDelta != 0 {
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: scrollDelta, visualLineReselect: true, updatesVisualLineEndpoint: false)
            guard performKeyboardCopyModeLineScroll(scrollDelta) else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
                reselectKeyboardCopyModeVisualLineSelection(surface: surface)
                return
            }
            resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            return
        }

        reselectKeyboardCopyModeVisualLineSelection(surface: surface)
    }

    private func handleKeyboardCopyModeIfNeeded(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        guard keyboardCopyModeActive else { return false }

        if terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: event.modifierFlags) {
            keyboardCopyModeInputState.reset()
            return false
        }

        // Use the visual-mode flag instead of raw has_selection; non-visual
        // cursor state is owned by the copy-mode cursor model.
        let hasSelection = keyboardCopyModeVisualActive
        let resolution = terminalKeyboardCopyModeResolve(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags,
            hasSelection: hasSelection,
            state: &keyboardCopyModeInputState
        )
        guard case let .perform(action, count) = resolution else {
            return true
        }

        switch action {
        case .exit:
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
            setKeyboardCopyModeActive(false)
        case .startSelection:
            if selectKeyboardCopyModeCursorCell(surface: surface) {
                keyboardCopyModeVisualActive = true
                keyboardCopyModeVisualLineSelection = nil
                keyboardCopyModeVisualLineRuntimeSelectionSynced = false
                syncKeyboardCopyModeCursorOverlay(surface: surface)
            }
        case .startLineSelection:
            startKeyboardCopyModeLineSelection(surface: surface, lineCount: count)
        case .clearSelection:
            clearKeyboardCopyModeVisualLineSelection(surface: surface)
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .copyAndExit:
            if copyKeyboardCopyModeSelectionToClipboard(surface: surface) { _ = GhosttyRuntimeCInterop.clearSelection(surface); setKeyboardCopyModeActive(false) }
        case .copyLineAndExit:
            let startRow = currentKeyboardCopyModeViewportRow(surface: surface)
            if copyCurrentViewportLinesToClipboard(
                surface: surface,
                startRow: startRow,
                lineCount: count
            ) {
                _ = GhosttyRuntimeCInterop.clearSelection(surface)
                setKeyboardCopyModeActive(false)
            }
        case let .scrollLines(delta):
            let lineDelta = delta * terminalKeyboardCopyModeClampCount(count)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: lineDelta)
            if performKeyboardCopyModeLineScroll(lineDelta) {
                resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            } else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
            }
        case let .scrollPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * rows * clampedCount)
            if performBindingAction(delta > 0 ? "scroll_page_down" : "scroll_page_up", repeatCount: clampedCount) {
                resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            } else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
            }
        case let .scrollHalfPage(delta):
            let clampedCount = terminalKeyboardCopyModeClampCount(count)
            let fraction = delta > 0 ? 0.5 : -0.5
            let rows = keyboardCopyModeGridMetrics(surface: surface)?.rows
                ?? max(Int(ghostty_surface_size(surface).rows), 1)
            let linesPerScroll = Int((Double(rows) * 0.5).rounded(.towardZero))
            beginKeyboardCopyModeViewportJumpCursorSync(fallbackLineDelta: delta * linesPerScroll * clampedCount)
            if performBindingAction("scroll_page_fractional:\(fraction)", repeatCount: clampedCount) {
                resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            } else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
            }
        case .scrollToTop:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.home, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    cursor.row = 0
                    cursor.column = 0
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_top")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case .scrollToBottom:
            if var cursor = keyboardCopyModeCursor {
                if let metrics = keyboardCopyModeGridMetrics(surface: surface) {
                    _ = cursor.move(.end, count: 1, rows: metrics.rows, columns: metrics.columns)
                } else {
                    let size = ghostty_surface_size(surface)
                    cursor.row = max(Int(size.rows) - 1, 0)
                    cursor.column = max(Int(size.columns) - 1, 0)
                }
                keyboardCopyModeCursor = cursor
            }
            _ = performBindingAction("scroll_to_bottom")
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        case let .jumpToPrompt(delta):
            beginKeyboardCopyModeViewportJumpCursorSync(visualLineReselect: keyboardCopyModeVisualLineActive, updatesVisualLineEndpoint: keyboardCopyModeVisualLineActive)
            if performBindingAction("jump_to_prompt:\(delta * count)") {
                resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            } else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
            }
        case .startSearch:
            _ = performBindingAction("start_search")
        case .searchNext:
            beginKeyboardCopyModeViewportJumpCursorSync(visualLineReselect: keyboardCopyModeVisualLineActive, updatesVisualLineEndpoint: keyboardCopyModeVisualLineActive)
            if performBindingAction("navigate_search:next", repeatCount: count) {
                resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            } else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
            }
        case .searchPrevious:
            beginKeyboardCopyModeViewportJumpCursorSync(visualLineReselect: keyboardCopyModeVisualLineActive, updatesVisualLineEndpoint: keyboardCopyModeVisualLineActive)
            if performBindingAction("navigate_search:previous", repeatCount: count) {
                resolveKeyboardCopyModeViewportJumpCursorSyncAfterBinding(surface: surface)
            } else {
                cancelKeyboardCopyModeViewportJumpCursorSyncIfNeeded(
                    generation: keyboardCopyModePendingViewportJumpGeneration
                )
            }
        case let .adjustSelection(direction):
            if keyboardCopyModeVisualLineActive {
                adjustKeyboardCopyModeVisualLineSelection(direction, count: count, surface: surface)
            } else if keyboardCopyModeVisualActive {
                adjustKeyboardCopyModeSelection(direction, count: count, surface: surface)
            } else {
                moveKeyboardCopyModeCursor(direction, count: count, surface: surface)
            }
        }
        return true
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        guard let surface else {
            _ = performBindingAction("copy_to_clipboard")
            return
        }
        _ = copyKeyboardCopyModeSelectionToClipboard(surface: surface)
    }

    @IBAction func copyWorkspaceAndSurfaceIdentifiers(_ sender: Any?) {
        guard let terminalSurface else { return }
        let paneId = terminalSurface.owningWorkspace()?.paneId(forPanelId: terminalSurface.id)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: terminalSurface.tabId,
                paneId: paneId,
                surfaceId: terminalSurface.id,
                includeRefs: true
            )
        )
    }

    @IBAction func copyCurrentSurfaceLink(_ sender: Any?) {
        guard let terminalSurface else { return }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        )
    }

    private func recordDirectAgentHibernationTerminalInput() {
        guard let terminalSurface else { return }
        recordAgentHibernationTerminalInput(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id
        )
    }

    // MARK: - Clipboard paste

    @IBAction func paste(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "paste.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    /// Pastes clipboard text as plain text, stripping any rich formatting.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        guard prepareSurfaceForPaste(reason: "pasteAsPlainText.missingSurface") else { return }
        recordDirectAgentHibernationTerminalInput()
        _ = performBindingAction("paste_from_clipboard")
    }

    private func applyConfiguredMenuShortcut(_ shortcut: StoredShortcut, to item: NSMenuItem) {
        guard let keyEquivalent = shortcut.menuItemKeyEquivalent else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    /// Validates whether edit menu items (copy, paste, split) should be enabled.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return hasCopyableTerminalSelection(surface: surface)
        case #selector(paste(_:)):
            return GhosttyApp.terminalPasteboard.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(pasteAsPlainText(_:)):
            return GhosttyApp.terminalPasteboard.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        case #selector(splitHorizontally(_:)), #selector(splitVertically(_:)):
            return canSplitCurrentSurface()
        case #selector(copyWorkspaceAndSurfaceIdentifiers(_:)):
            return terminalSurface != nil
        default:
            return true
        }
    }

    // MARK: - Accessibility

    /// Expose the terminal surface as an editable accessibility element.
    /// Voice input tools frequently target AX text areas for text insertion.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        // We don't keep a full terminal text snapshot in this layer.
        // Expose selected text when available; otherwise provide an empty value
        // so AX clients still treat this as an editable text area.
        accessibilitySelectedText() ?? ""
    }

    override func setAccessibilityValue(_ value: Any?) {
        let content: String
        switch value {
        case let v as NSAttributedString:
            content = v.string
        case let v as String:
            content = v
        default:
            return
        }

        guard !content.isEmpty else { return }

#if DEBUG
        cmuxDebugLog("ime.ax.setValue len=\(content.count)")
#endif

        let inject = {
            self.withExternalCommittedText {
                self.insertText(content, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    private func withExternalCommittedText<T>(_ body: () -> T) -> T {
        externalCommittedTextDepth += 1
        defer { externalCommittedTextDepth -= 1 }
        return body()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = readSelectionSnapshot() else { return nil }
        return snapshot.string.isEmpty ? nil : snapshot.string
    }

    private func readSelectionSnapshot(surface explicitSurface: ghostty_surface_t? = nil) -> SelectionSnapshot? {
        guard let surface = explicitSurface ?? self.surface else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected: String
        if let ptr = text.text, text.text_len > 0 {
            let selectedData = Data(bytes: ptr, count: Int(text.text_len))
            selected = String(decoding: selectedData, as: UTF8.self)
        } else {
            selected = ""
        }

        return SelectionSnapshot(
            range: NSRange(location: Int(text.offset_start), length: Int(text.offset_len)),
            string: selected,
            topLeft: CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        )
    }

    private func visibleDocumentRectInScreenCoordinates() -> NSRect {
        let localRect = visibleRect
        let windowRect = convert(localRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    private func invalidateTextInputCoordinates(selectionChanged: Bool = false) {
        guard let inputContext else { return }
        inputContext.invalidateCharacterCoordinates()
        guard selectionChanged else { return }

        // `textInputClientDidUpdateSelection` is absent from the Xcode 16.2 AppKit SDK
        // used by the macOS 14 compatibility lane, so call it dynamically when present.
        let updateSelectionSelector = NSSelectorFromString("textInputClientDidUpdateSelection")
        guard inputContext.responds(to: updateSelectionSelector) else { return }
        _ = inputContext.perform(updateSelectionSelector)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        var shouldApplySurfaceFocus = false
        if result {
            imeConsumedKeyUps.removeAll()
            if let terminalSurface,
               AppDelegate.shared?.allowsTerminalKeyboardFocus(
                   workspaceId: terminalSurface.tabId,
                   panelId: terminalSurface.id,
                   in: window
               ) == false {
                desiredFocus = false
                terminalSurface.recordExternalFocusState(false)
                terminalSurface.hostedView.cancelSuppressedFirstResponderFocusReapply()
#if DEBUG
                dlog("focus.firstResponder SUPPRESSED (coordinator) surface=\(terminalSurface.id.uuidString.prefix(5))")
#endif
                return result
            }

            // If we become first responder before the ghostty surface exists (e.g. during
            // split/tab creation while the surface is still being created), record the desired focus.
            desiredFocus = true

            // During programmatic splits, SwiftUI reparents the old NSView which triggers
            // becomeFirstResponder. Suppress onFocus + ghostty_surface_set_focus to prevent
            // the old view from stealing focus and creating model/surface divergence.
            if suppressingReparentFocus {
                let hiddenInHierarchy = isHiddenOrHasHiddenAncestor
                if isVisibleInUI && (!hasUsableFocusGeometry || hiddenInHierarchy) {
                    terminalSurface?.hostedView.scheduleSuppressedFirstResponderFocusReapply(
                        reason: "becomeFirstResponder.reparent.hiddenOrTiny"
                    )
                }
#if DEBUG
                cmuxDebugLog("focus.firstResponder SUPPRESSED (reparent) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                return result
            }

            // Always notify the host app that this pane became the first responder so bonsplit
            // focus/selection can converge. Previously this was gated on `surface != nil`, which
            // allowed a mismatch where AppKit focus moved but the UI focus indicator (bonsplit)
            // stayed behind.
            let hiddenInHierarchy = isHiddenOrHasHiddenAncestor
            if isVisibleInUI && hasUsableFocusGeometry && !hiddenInHierarchy {
                shouldApplySurfaceFocus = true
                onFocus?()
            } else if isVisibleInUI && (!hasUsableFocusGeometry || hiddenInHierarchy) {
#if DEBUG
                cmuxDebugLog(
                    "focus.firstResponder SUPPRESSED (hidden_or_tiny) surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) hidden=\(hiddenInHierarchy ? 1 : 0)"
                )
#endif
                terminalSurface?.hostedView.scheduleSuppressedFirstResponderFocusReapply(
                    reason: "becomeFirstResponder.hiddenOrTiny"
                )
            }
        }
        if result, shouldApplySurfaceFocus, let surface = ensureSurfaceReadyForInput() {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
#if DEBUG
            cmuxDebugLog("focus.firstResponder surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            if let terminalSurface {
                NotificationCenter.default.post(
                    name: .ghosttyDidBecomeFirstResponderSurface,
                    object: nil,
                    userInfo: [
                        GhosttyNotificationKey.tabId: terminalSurface.tabId,
                        GhosttyNotificationKey.surfaceId: terminalSurface.id,
                    ]
                )
            }
            terminalSurface?.recordExternalFocusState(true)
            terminalSurface?.hostedView.cancelSuppressedFirstResponderFocusReapply()
            ghostty_surface_set_focus(surface, true)

            // Ghostty only restarts its vsync display link on display-id changes while focused.
            // During rapid split close / SwiftUI reparenting, the view can reattach to a window
            // and get its display id set *before* it becomes first responder; in that case, the
            // renderer can remain stuck until some later screen/focus transition. Reassert the
            // display id now that we're focused to ensure the renderer is running.
            if let displayID = window?.screen?.displayID, displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
            terminalSurface?.forceRefresh(reason: "focus.firstResponder")
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            imeConsumedKeyUps.removeAll()
            desiredFocus = false
            terminalSurface?.hostedView.cancelSuppressedFirstResponderFocusReapply()
            terminalSurface?.recordExternalFocusState(false)
        }
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("resignFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // For NSTextInputClient - accumulates text during key events
    private(set) var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()
    private var markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var lastPerformKeyEvent: TimeInterval?
    private(set) var externalCommittedTextDepth = 0
    var numpadIMECommitDeduplicator = NumpadIMECommitDeduplicator()
    private struct SelectionSnapshot {
        let range: NSRange
        let string: String
        let topLeft: CGPoint
    }

#if DEBUG
    // Test-only accessors for keyTextAccumulator to verify CJK IME composition behavior.
    func setKeyTextAccumulatorForTesting(_ value: [String]?) {
        keyTextAccumulator = value
    }
    var keyTextAccumulatorForTesting: [String]? {
        keyTextAccumulator
    }
    func shouldSuppressShiftSpaceFallbackTextForTesting(event: NSEvent, markedTextBefore: Bool) -> Bool {
        shouldSuppressShiftSpaceFallbackText(event: event, markedTextBefore: markedTextBefore)
    }
    // Test-only IME point override so firstRect behavior can be regression tested.
    private var imePointOverrideForTesting: (x: Double, y: Double, width: Double, height: Double)?
    func setIMEPointForTesting(x: Double, y: Double, width: Double, height: Double) { imePointOverrideForTesting = (x, y, width, height) }
    func clearIMEPointForTesting() { imePointOverrideForTesting = nil }
#endif

#if DEBUG
    private func recordKeyLatency(path: String, event: NSEvent) {
        guard Self.keyLatencyProbeEnabled else { return }
        CmuxTypingTiming.logEventDelay(path: path, event: event)
    }
#endif

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    /// Some third-party voice input apps inject committed text by sending the
    /// responder-chain `insertText:` action (single-argument form).
    /// Route that into our NSTextInputClient path so text lands in the terminal.
    override func insertText(_ insertString: Any) {
        withExternalCommittedText {
            insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: true)
    }

    func performKeyEquivalentAfterMenuMiss(with event: NSEvent) -> Bool {
        performKeyEquivalent(with: event, shouldRetryMainMenu: false)
    }

    private func performKeyEquivalent(with event: NSEvent, shouldRetryMainMenu: Bool) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
#endif
        guard event.type == .keyDown else { return false }
        guard let fr = window?.firstResponder as? NSView,
              fr === self || fr.isDescendant(of: self) else { return false }
        guard let surface = ensureSurfaceReadyForInput() else { return false }

        // Let non-Cmd keys flow to keyDown while IME is composing; Cmd shortcuts still work.
        if hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            return false
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // Printable text without Command/Control should stay on the normal keyDown
        // path. AppKit can still route layout-dependent punctuation through
        // performKeyEquivalent first, and probing bindings here can misclassify
        // keys such as ABC-QWERTZ Shift+7 ("/") or Shift+- ("?") as shortcuts.
        if !flags.contains(.command),
           !flags.contains(.control),
           let text = textForKeyEvent(event),
           shouldSendText(text) {
            lastPerformKeyEvent = nil
            return false
        }

#if DEBUG
        recordKeyLatency(path: "performKeyEquivalent", event: event)
#endif

#if DEBUG
        TerminalChildExitProbe().write(
            [
                "probePerformCharsHex": (event.characters?.unicodeScalarHexList ?? ""),
                "probePerformCharsIgnoringHex": (event.charactersIgnoringModifiers?.unicodeScalarHexList ?? ""),
                "probePerformKeyCode": String(event.keyCode),
                "probePerformModsRaw": String(event.modifierFlags.rawValue),
                "probePerformSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probePerformKeyEquivalentCount": 1]
        )
#endif

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
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

            // If the binding is consumed and not meant for the menu, allow menu first.
            // Performable bindings (e.g. paste_from_clipboard) also need the menu
            // path so that Edit > Paste handles Cmd+V instead of keyDown double-
            // firing the clipboard request through both interpretKeyEvents and
            // ghostty_surface_key.
            if shouldRetryMainMenu && isConsumed && !isAll && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            // For performable bindings where the menu didn't handle the event,
            // fall through to keyDown so Ghostty can perform the action directly
            // (e.g. paste when no menu item exists).
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

            // Match AppKit key-equivalent routing for menu-style shortcuts (Command-modified).
            // Control-only terminal input (e.g. Ctrl+D) should not participate in redispatch;
            // it must flow through the normal keyDown path exactly once.
            if !event.modifierFlags.contains(.command) {
                lastPerformKeyEvent = nil
                return false
            }

            if !shouldRetryMainMenu { lastPerformKeyEvent = nil; keyDown(with: event); return true }
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.charactersIgnoringModifiers ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp; return false
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
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        let phaseTotalStart = ProcessInfo.processInfo.systemUptime
        var ensureSurfaceMs: Double = 0
        var dismissNotificationMs: Double = 0
        var keyboardCopyModeMs: Double = 0
        var interpretMs: Double = 0
        var syncPreeditMs: Double = 0
        var ghosttySendMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "terminal.keyDown.phase",
                totalMs: totalMs,
                event: event,
                thresholdMs: 1.0,
                parts: [
                    ("ensureSurfaceMs", ensureSurfaceMs),
                    ("dismissNotificationMs", dismissNotificationMs),
                    ("keyboardCopyModeMs", keyboardCopyModeMs),
                    ("interpretMs", interpretMs),
                    ("syncPreeditMs", syncPreeditMs),
                    ("ghosttySendMs", ghosttySendMs),
                ],
                extra: "marked=\(hasMarkedText() ? 1 : 0)"
            )
            CmuxTypingTiming.logDuration(path: "terminal.keyDown", startedAt: typingTimingStart, event: event)
        }
        let ensureSurfaceStart = ProcessInfo.processInfo.systemUptime
#endif
        guard let surface = ensureSurfaceReadyForInput() else {
            requestInputRecoveryAfterSurfaceMiss(reason: "keyDown.missingSurface")
#if DEBUG
            ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
            super.keyDown(with: event)
            return
        }
        recordDirectAgentHibernationTerminalInput()
#if DEBUG
        ensureSurfaceMs = (ProcessInfo.processInfo.systemUptime - ensureSurfaceStart) * 1000.0
#endif
        if let appDelegate = AppDelegate.shared,
           let mode = appDelegate.rightSidebarModeShortcut(for: event),
           let window,
           appDelegate.shouldRouteRightSidebarModeShortcut(in: window) {
            _ = appDelegate.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
            return
        }
        if let terminalSurface {
#if DEBUG
            let dismissNotificationStart = ProcessInfo.processInfo.systemUptime
#endif
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
#if DEBUG
            dismissNotificationMs = (ProcessInfo.processInfo.systemUptime - dismissNotificationStart) * 1000.0
#endif
        }
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if !cmuxFindEventIsPlainEscape(event) { endFindEscapeSuppression() }
        if shouldConsumeSuppressedFindEscape(event) { return }
        if cmuxFindEventIsPlainEscape(event), !hasMarkedText(), let terminalSurface, terminalSurface.searchState != nil {
            terminalSurface.searchState = nil
            beginFindEscapeSuppression(); return
        }
#if DEBUG
        let keyboardCopyModeStart = ProcessInfo.processInfo.systemUptime
#endif
        if handleKeyboardCopyModeIfNeeded(event, surface: surface) {
#if DEBUG
            keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
            keyboardCopyModeConsumedKeyUps.insert(event.keyCode)
            return
        }
#if DEBUG
        keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
#if DEBUG
        recordKeyLatency(path: "keyDown", event: event)
#endif

#if DEBUG
        TerminalChildExitProbe().write(
            [
                "probeKeyDownCharsHex": (event.characters?.unicodeScalarHexList ?? ""),
                "probeKeyDownCharsIgnoringHex": (event.charactersIgnoringModifiers?.unicodeScalarHexList ?? ""),
                "probeKeyDownKeyCode": String(event.keyCode),
                "probeKeyDownModsRaw": String(event.modifierFlags.rawValue),
                "probeKeyDownSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeKeyDownCount": 1]
        )
#endif

        // Fast path for control-modified terminal input (for example Ctrl+D).
        //
        // These keys are terminal control input, not text composition, so we bypass
        // AppKit text interpretation and send a single deterministic Ghostty key event.
        // This avoids intermittent drops after rapid split close/reparent transitions.
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

            let text = (event.charactersIgnoringModifiers ?? event.characters ?? "")
            let handled: Bool
            if text.isEmpty {
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                handled = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ctrlGhosttySend",
                    event: event
                )
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                handled = ghostty_surface_key(surface, keyEvent)
                #endif
            } else {
                #if DEBUG
                let sendTimingStart = CmuxTypingTiming.start()
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                #endif
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
                #if DEBUG
                ghosttySendMs = (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "terminal.keyDown.ctrlGhosttySend",
                    startedAt: sendTimingStart,
                    event: event,
                    extra: "handled=\(handled ? 1 : 0)"
                )
                #endif
            }
#if DEBUG
            cmuxDebugLog(
                "key.ctrl path=ghostty surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "handled=\(handled ? 1 : 0) keyCode=\(event.keyCode) chars=\((event.characters?.unicodeScalarHexList ?? "")) " +
                "ign=\((event.charactersIgnoringModifiers?.unicodeScalarHexList ?? "")) mods=\(event.modifierFlags.rawValue)"
            )
#endif
            // If Ghostty handled the key (action/encoding), we're done.
            // If not (e.g. `ignore` keybind), fall through to interpretKeyEvents
            // so the IME gets a chance to process this event.
            if handled { return }
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        let translationMods = cmuxTranslationModifierFlags(
            original: event.modifierFlags,
            ghosttyTranslationMods: translationModsGhostty
        )

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
        let textInputEvent = textInputInterpretationEvent(
            original: event,
            translated: translationEvent
        )

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let markedStateBefore = (markedText.string, markedSelectedRange)

        // Capture the keyboard layout ID before interpretation so the IME
        // forwarding decision uses the source that saw this key.
        let keyboardIdBefore = KeyboardLayout.id

        // Let the input system handle the event (for IME, dead keys, etc.)
#if DEBUG
        let interpretTimingStart = CmuxTypingTiming.start()
        let interpretPhaseStart = ProcessInfo.processInfo.systemUptime
#endif
#if DEBUG
        if let debugTextInputEventHandler = Self.debugTextInputEventHandler {
            let handled = debugTextInputEventHandler(self, textInputEvent)
            if !handled {
                interpretKeyEvents([textInputEvent])
            }
        } else {
            interpretKeyEvents([textInputEvent])
        }
#else
        interpretKeyEvents([textInputEvent])
#endif
#if DEBUG
        interpretMs = (ProcessInfo.processInfo.systemUptime - interpretPhaseStart) * 1000.0
        CmuxTypingTiming.logDuration(
            path: "terminal.keyDown.interpretKeyEvents",
            startedAt: interpretTimingStart,
            event: event
        )
#endif

        // If the keyboard layout changed, an input method grabbed the event.
        // Sync preedit and return without sending the key to Ghostty.
        if !markedTextBefore, let kbBefore = keyboardIdBefore, kbBefore != KeyboardLayout.id {
            imeConsumedKeyUps.insert(event.keyCode)
#if DEBUG
            let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
            syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
            syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif
            return
        }

        // Sync preedit so Ghostty can render the IME composition overlay.
#if DEBUG
        let syncPreeditStart = ProcessInfo.processInfo.systemUptime
#endif
        syncPreedit(clearIfNeeded: markedTextBefore)
#if DEBUG
        syncPreeditMs = (ProcessInfo.processInfo.systemUptime - syncPreeditStart) * 1000.0
#endif

        let accumulatedText = keyTextAccumulator ?? []
        if shouldSuppressGhosttyKeyForwardingAfterIMEHandling(
            before: markedStateBefore,
            after: (markedText.string, markedSelectedRange),
            accumulatedText: accumulatedText,
            event: textInputEvent,
            inputSourceId: keyboardIdBefore
        ) {
            imeConsumedKeyUps.insert(event.keyCode)
            return
        }

        // A forwarded keyDown owns its keyUp. Clear any stale IME suppression
        // entry left by an earlier suppressed repeat for the same physical key.
        imeConsumedKeyUps.remove(event.keyCode)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Treat cleared preedit as composing too, so a composing Backspace cancels
        // composition without deleting the preceding terminal input.
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        // Use accumulated text from insertText (for IME), or compute text for key
        if !accumulatedText.isEmpty {
            // Accumulated text comes from insertText (IME composition result).
            // These never have "composing" set to true because these are the
            // result of a composition.
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        _ = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.accumulatedGhosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        _ = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.accumulatedGhosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.accumulatedGhosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            }

            if shouldSendCommittedIMEConfirmKey(
                event: textInputEvent,
                markedTextBefore: markedTextBefore
            ) {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
#if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.accumulatedConfirmGhosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
#else
                _ = ghostty_surface_key(surface, keyEvent)
#endif
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            let suppressShiftSpaceFallbackText =
                shouldSuppressShiftSpaceFallbackText(
                    event: translationEvent,
                    markedTextBefore: markedTextBefore
                )
            let suppressComposingFallbackText = keyEvent.composing
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text),
                   !suppressShiftSpaceFallbackText,
                   !suppressComposingFallbackText {
                    var handled = false
#if DEBUG
                    let sendTimingStart = CmuxTypingTiming.start()
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
#endif
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        #if DEBUG
                        handled = sendTimedGhosttyKey(
                            surface,
                            keyEvent,
                            path: "terminal.keyDown.ghosttySend",
                            event: event,
                            extra: "textBytes=\(text.utf8.count)"
                        )
                        #else
                        handled = sendGhosttyKey(surface, keyEvent)
                        #endif
                    }
                    if handled {
                        notePotentialDeferredNumpadIMECommit(text: text, event: event)
                    }
#if DEBUG
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "terminal.keyDown.ghosttySend.total",
                        startedAt: sendTimingStart,
                        event: event,
                        extra: "handled=\(handled ? 1 : 0) textBytes=\(text.utf8.count)"
                    )
#endif
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    #if DEBUG
                    let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                    _ = sendTimedGhosttyKey(
                        surface,
                        keyEvent,
                        path: "terminal.keyDown.ghosttySend",
                        event: event
                    )
                    ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                    #else
                    _ = ghostty_surface_key(surface, keyEvent)
                    #endif
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                #if DEBUG
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                _ = sendTimedGhosttyKey(
                    surface,
                    keyEvent,
                    path: "terminal.keyDown.ghosttySend",
                    event: event
                )
                ghosttySendMs += (ProcessInfo.processInfo.systemUptime - ghosttySendStart) * 1000.0
                #else
                _ = ghostty_surface_key(surface, keyEvent)
                #endif
            }
        }

        // Rendering is driven by Ghostty's wakeups/renderer.
    }

    @discardableResult
    private func sendGhosttyKey(_ surface: ghostty_surface_t, _ keyEvent: ghostty_input_key_s) -> Bool {
#if DEBUG
        Self.debugGhosttySurfaceKeyEventObserver?(keyEvent)
#endif
        return ghostty_surface_key(surface, keyEvent)
    }

#if DEBUG
    @discardableResult
    private func sendTimedGhosttyKey(
        _ surface: ghostty_surface_t,
        _ keyEvent: ghostty_input_key_s,
        path: String,
        event: NSEvent? = nil,
        extra: String? = nil
    ) -> Bool {
        let timingStart = CmuxTypingTiming.start()
        let handled = sendGhosttyKey(surface, keyEvent)
        let baseExtra = "handled=\(handled ? 1 : 0)"
        let mergedExtra: String
        if let extra, !extra.isEmpty {
            mergedExtra = "\(baseExtra) \(extra)"
        } else {
            mergedExtra = baseExtra
        }
        CmuxTypingTiming.logDuration(path: path, startedAt: timingStart, event: event, extra: mergedExtra)
        return handled
    }
#endif

    override func keyUp(with event: NSEvent) {
        guard let surface = ensureSurfaceReadyForInput() else {
            super.keyUp(with: event)
            return
        }
        if event.keyCode != 53 {
            endFindEscapeSuppression()
        }
        if shouldConsumeSuppressedFindEscape(event) {
            endFindEscapeSuppression()
            return
        }
        if event.keyCode == 53 {
            endFindEscapeSuppression()
        }

        if keyboardCopyModeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }
        if imeConsumedKeyUps.remove(event.keyCode) != nil {
            return
        }

        // Build release events from the same translation path as keyDown so
        // consumers that depend on precise key identity (for example Space
        // hold/release flows) receive consistent metadata.
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = sendGhosttyKey(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        if !hasMarkedText(),
           let action = ghostty_input_action_e.modifierActionForFlagsChanged(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue
           ) {
            // `flagsChanged` carries modifier-only state, not textual key input.
            // Building this via `ghosttyKeyEvent(for:surface:)` would fall through
            // to `unshiftedCodepointFromEvent`, which probes AppKit character APIs
            // that are not safe for modifier-only events.
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = 0
            _ = sendGhosttyKey(surface, keyEvent)
        }

        let selectionActive = ghostty_surface_has_selection(surface)
        let suppressCommandPathHover = event.modifierFlags.contains(.command) && selectionActive
        // Refresh ghostty's mouse position so quicklook_word uses current coordinates
        // when Cmd is pressed while the pointer is stationary.
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        let point = preferredPointerPoint(from: eventPoint) ?? eventPoint
#if DEBUG
        if event.modifierFlags.contains(.command) || selectionActive {
            runtimeDebugLog(
                hypothesisID: "h1",
                name: "flags_changed",
                expected: "selection active should suppress cmd-hover",
                actual: suppressCommandPathHover ? "suppressed" : "forwarded",
                data: [
                    "flags": debugModifierString(event.modifierFlags),
                    "selection_active": selectionActive,
                    "point_x": eventPoint.x,
                    "point_y": eventPoint.y,
                    "resolved_point_x": point.x,
                    "resolved_point_y": point.y
                ]
            )
        }
#endif
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            bounds.height - point.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: point,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func shouldSuppressCommandPathHover(for flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command), let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    private func hoverModsFromFlags(
        _ flags: NSEvent.ModifierFlags,
        suppressCommandPathHover: Bool
    ) -> ghostty_input_mods_e {
        let effectiveFlags = suppressCommandPathHover ? flags.subtracting(.command) : flags
#if DEBUG
        if suppressCommandPathHover, flags.contains(.command) {
            _ = UITestCaptureSink().mutateJSONObjectIfConfigured(
                envKey: "CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"
            ) { payload in
                payload["suppressed_command_hover_count"] = (payload["suppressed_command_hover_count"] as? Int ?? 0) + 1
            }
        }
#endif
        return mouseModsFromFlags(effectiveFlags)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        cmuxGhosttyModsFromFlags(modifierFlagsRawValue: flags.rawValue)
    }

    private func mouseModsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        mouseModsFromFlags(event.modifierFlags)
    }

    private func mouseModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        cmuxGhosttyMouseModsFromFlags(modifierFlagsRawValue: flags.rawValue)
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

    func beginFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = true
    }

    private func endFindEscapeSuppression() {
        isFindEscapeSuppressionArmed = false
    }

    private func shouldConsumeSuppressedFindEscape(_ event: NSEvent) -> Bool {
        isFindEscapeSuppressionArmed && cmuxFindEventIsPlainEscape(event)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
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
        if let layoutChars = KeyboardLayout.character(forKeyCode: event.keyCode),
           layoutChars.count == 1,
           let layoutScalar = layoutChars.unicodeScalars.first,
           layoutScalar.value >= 0x20,
           !(layoutScalar.value >= 0xF700 && layoutScalar.value <= 0xF8FF) {
            return layoutScalar.value
        }

        guard let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// If AppKit consumed Shift+Space for IME/input-source switching, interpretKeyEvents
    /// can return without insertText and without a detectable layout ID change.
    /// In that case we must not synthesize a literal space fallback.
    private func shouldSuppressShiftSpaceFallbackText(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedText.length == 0 else { return false }
        return true
    }

    private func shouldSendCommittedIMEConfirmKey(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard markedTextBefore, markedText.length == 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        // Korean IME: Enter commits the syllable AND executes the command (single step).
        // Japanese/Chinese IME: Enter only confirms the conversion; a second Enter executes.
        // Only send the extra Return key for Korean input sources.
        guard let sourceId = KeyboardLayout.id else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        let translationMods = cmuxTranslationModifierFlags(
            original: event.modifierFlags,
            ghosttyTranslationMods: translationModsGhostty
        )

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
            let name: String
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                name = String(data: data, encoding: .utf8) ?? ""
            } else {
                name = ""
            }
            keyTables.append(name)
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }

        terminalSurface?.hostedView.syncKeyStateIndicator(text: currentKeyStateIndicatorText)
    }

    // MARK: - Mouse Handling

    #if DEBUG
    private func debugModifierString(_ flags: NSEvent.ModifierFlags) -> String {
        [
            flags.contains(.command) ? "cmd" : nil,
            flags.contains(.shift) ? "shift" : nil,
            flags.contains(.control) ? "ctrl" : nil,
            flags.contains(.option) ? "opt" : nil,
        ].compactMap { $0 }.joined(separator: "+")
    }

    private func runtimeDebugLog(
        hypothesisID: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        var payload = data
        payload["surface_id"] = terminalSurface?.id.uuidString ?? "nil"
        payload["word_path_hover_active"] = wordPathHoverActive
        CmuxRuntimeDebugCapture.logIfConfigured(
            hypothesisID: hypothesisID,
            source: "GhosttyNSView.\(name)",
            name: name,
            expected: expected,
            actual: actual,
            data: payload
        )
    }

    private func runtimeDebugResolutionPayload(_ resolution: WordPathResolution?) -> [String: Any] {
        guard let resolution else {
            return [
                "resolution_source": "none",
                "resolved_path_basename": "",
                "raw_token": ""
            ]
        }

        return [
            "resolution_source": resolution.source.rawValue,
            "resolved_path_basename": URL(fileURLWithPath: resolution.path).lastPathComponent,
            "raw_token": resolution.rawToken
        ]
    }
    #endif

    private func requestPointerFocusRecovery() {
#if DEBUG
        cmuxDebugLog("focus.pointerDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
        onFocus?()
    }

    override func mouseDown(with event: NSEvent) {
        #if DEBUG
        let debugPoint = convert(event.locationInWindow, from: nil)
        cmuxDebugLog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))] clickCount=\(event.clickCount) point=(\(String(format: "%.0f", debugPoint.x)),\(String(format: "%.0f", debugPoint.y)))")
        #endif
        // Split reparent/layout churn can suppress the later `becomeFirstResponder -> onFocus`
        // callback. Treat pointer-down as explicit focus intent so clicking a ghost pane still
        // repairs workspace/pane active state before key routing runs.
        if let terminalSurface {
            if terminalSurface.focusPlacement == .rightSidebarDock {
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
            } else {
                AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                    workspaceId: terminalSurface.tabId,
                    panelId: terminalSurface.id,
                    in: window
                )
            }
            terminalSurface.hostedView.clearReparentFocusSuppressionForPointerFocus()
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        if let terminalSurface {
            AppDelegate.shared?.tabManager?.dismissNotificationOnTerminalInteraction(
                tabId: terminalSurface.tabId,
                surfaceId: terminalSurface.id
            )
        }
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Only update mouse position on the first click to prevent unwanted cursor
        // movement during double-click selection (issue #1698)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, mouseModsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mouseModsFromEvent(event))
        hasPendingLeftMouseRelease = true
    }

    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        cmuxDebugLog("terminal.mouseUp surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))]")
        #endif
        completePendingLeftMouseRelease(with: event)
    }

    @discardableResult
    func forwardPendingLeftMouseDrag(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease, let surface else { return false }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, mouseModsFromEvent(event))
        return true
    }

    @discardableResult
    func completePendingLeftMouseRelease(with event: NSEvent) -> Bool {
        guard hasPendingLeftMouseRelease else { return false }
        hasPendingLeftMouseRelease = false
        guard let surface else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let consumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mouseModsFromEvent(event))
        _ = handleCommandClickRelease(at: point, modifierFlags: event.modifierFlags, ghosttyConsumed: consumed)
        return true
    }

    /// Attempt to open the word under the mouse cursor as a file path, resolved
    /// against the terminal panel's current working directory.
    private func tryOpenWordAsPath(at point: NSPoint? = nil) {
        guard let resolution = resolveWordUnderCursorPath(at: point) else { return }

        #if DEBUG
        cmuxDebugLog("link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue)")
        #endif

        PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: resolution.path))
    }

    /// Check if the word under the mouse cursor resolves to an existing file/directory
    /// in the terminal panel's CWD. Returns the resolved absolute path, or nil.
    private func resolveWordUnderCursorAsPath(at point: NSPoint? = nil) -> String? {
        resolveWordUnderCursorPath(at: point)?.path
    }

    private func resolveWordUnderCursorPath(at point: NSPoint? = nil) -> WordPathResolution? {
        guard let surface = surface else { return nil }

        guard let termSurface = terminalSurface,
              let workspace = termSurface.owningWorkspace(),
              !workspace.isRemoteTerminalSurface(termSurface.id) else { return nil }

        guard let cwd = resolvedWordPathWorkingDirectory(workspace: workspace, terminalSurface: termSurface) else {
            return nil
        }

        let snapshotPoint = preferredPointerPoint(from: point)
        let pointSnapshotResolution = snapshotPoint.flatMap {
            resolveVisibleWordPath(
                at: $0,
                cwd: cwd,
                workspace: workspace,
                terminalSurface: termSurface
            )
        }

        var text = ghostty_text_s()
        if ghostty_surface_quicklook_word(surface, &text) {
            defer { ghostty_surface_free_text(surface, &text) }
            var quicklookResolution: WordPathResolution?
            if text.text_len > 0, let ptr = text.text {
                let wordData = Data(bytes: ptr, count: Int(text.text_len))
                if let decodedWord = String(bytes: wordData, encoding: .utf8) {
#if DEBUG
                    let resolvedQuicklookWord = cmuxTerminalCmdClickQuicklookOverride(decodedWord)
#else
                    let resolvedQuicklookWord = decodedWord
#endif
                    if let resolvedPath = TerminalPathResolver().resolveQuicklookPath(resolvedQuicklookWord, cwd: cwd) {
                        quicklookResolution = makeWordPathResolution(
                            path: resolvedPath,
                            source: .quicklook,
                            rawToken: resolvedQuicklookWord
                        )
                    }
                }
            }

            var viewportResolution: WordPathResolution?
            if text.offset_len > 0 {
#if DEBUG
                let viewportOffsetStart = cmuxTerminalCmdClickViewportOffsetDelta(Int(text.offset_start))
#else
                let viewportOffsetStart = Int(text.offset_start)
#endif
                viewportResolution = resolveVisibleWordPathFromViewportOffset(
                    viewportOffsetStart,
                    cwd: cwd,
                    workspace: workspace,
                    terminalSurface: termSurface
                )
            }

            if let viewportResolution {
                // The pointer-anchored snapshot is the only source tied directly to the
                // actual click location. Prefer it over quicklook and viewport offsets,
                // which can lag or target a sibling entry in multi-column `ls` output.
                if let pointSnapshotResolution {
                    return pointSnapshotResolution
                }
                return viewportResolution
            }

            if let pointSnapshotResolution {
                return pointSnapshotResolution
            }

            if let quicklookResolution {
                return quicklookResolution
            }
        }

        return pointSnapshotResolution
    }

    #if DEBUG
    private func cmuxTerminalCmdClickQuicklookOverride(_ decodedWord: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard let override = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty else {
            return decodedWord
        }
        return override
    }

    private func cmuxTerminalCmdClickViewportOffsetDelta(_ viewportOffsetStart: Int) -> Int {
        let env = ProcessInfo.processInfo.environment
        guard let delta = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let parsedDelta = Int(delta) else {
            return viewportOffsetStart
        }
        return max(0, viewportOffsetStart + parsedDelta)
    }
    #endif

    /// Update the pointing-hand cursor when Cmd-hovering over a bare filename
    /// that exists in the terminal's CWD.
    private func updateWordPathHover(
        at point: NSPoint? = nil,
        cmdHeld: Bool,
        suppressPathHover: Bool = false
    ) {
        let hoverWasActive = wordPathHoverActive
        guard cmdHeld, !suppressPathHover else {
            if wordPathHoverActive {
                wordPathHoverActive = false
                NSCursor.pop()
            }
#if DEBUG
            if cmdHeld || suppressPathHover || hoverWasActive {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "hover_update",
                    expected: "cmd-hover off while selection is active",
                    actual: suppressPathHover ? "suppressed" : "inactive",
                    data: [
                        "cmd_held": cmdHeld,
                        "suppress_path_hover": suppressPathHover,
                        "hover_active_before": hoverWasActive,
                        "hover_active_after": wordPathHoverActive
                    ]
                )
            }
#endif
            return
        }

        let resolution = resolveWordUnderCursorPath(at: point)
        if resolution != nil {
            if !wordPathHoverActive {
                wordPathHoverActive = true
                NSCursor.pointingHand.push()
            }
        } else if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
#if DEBUG
        if cmdHeld || hoverWasActive || wordPathHoverActive || resolution != nil {
            var payload: [String: Any] = [
                "cmd_held": cmdHeld,
                "suppress_path_hover": suppressPathHover,
                "hover_active_before": hoverWasActive,
                "hover_active_after": wordPathHoverActive
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: resolution == nil ? "h1" : "h2",
                name: "hover_update",
                expected: "resolved path only when hover should activate",
                actual: wordPathHoverActive ? "hover_active" : "hover_inactive",
                data: payload
            )
        }
#endif
    }

    private func resolvedWordPathWorkingDirectory(
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> String? {
        CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: workspace,
            surfaceId: terminalSurface.id
        )
    }

    private func pointIsUsableForWordResolution(_ point: NSPoint) -> Bool {
        bounds.width > 0 &&
        bounds.height > 0 &&
        point.x >= 0 &&
        point.y >= 0 &&
        point.x <= bounds.width &&
        point.y <= bounds.height
    }

    private func trackMousePointIfUsable(_ point: NSPoint) {
        guard pointIsUsableForWordResolution(point) else { return }
        lastKnownMousePointInView = point
    }

    private func preferredPointerPoint(from eventPoint: NSPoint? = nil) -> NSPoint? {
        if let eventPoint, pointIsUsableForWordResolution(eventPoint) {
            lastKnownMousePointInView = eventPoint
            return eventPoint
        }
        if let currentPoint = currentMousePointInView(), pointIsUsableForWordResolution(currentPoint) {
            lastKnownMousePointInView = currentPoint
            return currentPoint
        }
        return lastKnownMousePointInView ?? eventPoint
    }

    private func currentMousePointInView() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func resolveVisibleWordPathFromViewportOffset(
        _ viewportOffsetStart: Int,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = visibleText.visibleLines(rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let rowFromTop = max(0, min(rows - 1, viewportOffsetStart / cols))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, viewportOffsetStart % cols))
        guard let resolution = TerminalPathResolver().resolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    private func resolveVisibleWordPath(
        at point: NSPoint,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = workspace.terminalPanel(for: terminalSurface.id),
              let surface else {
            return nil
        }

        let size = ghostty_surface_size(surface)
        let rows = max(Int(size.rows), 1)
        let cols = max(Int(size.columns), 1)
        let resolvedCellWidth = cellSize.width > 0 ? cellSize.width : CGFloat(size.cell_width_px)
        let resolvedCellHeight = cellSize.height > 0 ? cellSize.height : CGFloat(size.cell_height_px)
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
            terminalPanel: panel,
            lineLimit: max(200, rows * 4)
        ) ?? ""
        let visibleLines = visibleText.visibleLines(rows: rows)
        let rowOffset = max(0, rows - visibleLines.count)
        let xInset = max(0, (bounds.width - (CGFloat(cols) * resolvedCellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * resolvedCellHeight)) / 2)

        let yFromTop = bounds.height - point.y
        let rowFromTop = max(0, min(rows - 1, Int((yFromTop - yInset) / resolvedCellHeight)))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(cols - 1, Int((point.x - xInset) / resolvedCellWidth)))
        guard let resolution = TerminalPathResolver().resolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return makeWordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    @discardableResult
    private func handleCommandClickRelease(
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        ghosttyConsumed: Bool
    ) -> WordPathResolution? {
        guard let surface else { return nil }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: modifierFlags)
        let cmdHeld = modifierFlags.contains(.command)
        let resolvedPoint = preferredPointerPoint(from: point)
        guard cmdHeld, !suppressCommandPathHover else {
#if DEBUG
            if cmdHeld || suppressCommandPathHover {
                runtimeDebugLog(
                    hypothesisID: "h1",
                    name: "command_click_release",
                    expected: "cmd-click fallback only when selection is inactive",
                    actual: suppressCommandPathHover ? "suppressed" : "not_cmd_click",
                    data: [
                        "flags": debugModifierString(modifierFlags),
                        "ghostty_consumed": ghosttyConsumed,
                        "point_x": point.x,
                        "point_y": point.y,
                        "resolved_point_x": resolvedPoint?.x ?? -1,
                        "resolved_point_y": resolvedPoint?.y ?? -1,
                        "suppress_path_hover": suppressCommandPathHover
                    ]
                )
            }
#endif
            return nil
        }

        // Refresh ghostty's cached mouse position so quicklook_word reads
        // up-to-date coordinates (mouseDown skips pos update on double-click).
        if let resolvedPoint {
            ghostty_surface_mouse_pos(
                surface,
                resolvedPoint.x,
                bounds.height - resolvedPoint.y,
                mouseModsFromFlags(modifierFlags)
            )
        }

        guard let resolution = resolveWordUnderCursorPath(at: resolvedPoint) else {
#if DEBUG
            runtimeDebugLog(
                hypothesisID: "h2",
                name: "command_click_release",
                expected: "cmd-click should resolve the token under the pointer",
                actual: "no_resolution",
                data: [
                    "flags": debugModifierString(modifierFlags),
                    "ghostty_consumed": ghosttyConsumed,
                    "point_x": point.x,
                    "point_y": point.y,
                    "resolved_point_x": resolvedPoint?.x ?? -1,
                    "resolved_point_y": resolvedPoint?.y ?? -1
                ]
            )
#endif
            return nil
        }
        guard !ghosttyConsumed || resolution.source == .snapshot else {
#if DEBUG
            var payload: [String: Any] = [
                "flags": debugModifierString(modifierFlags),
                "ghostty_consumed": ghosttyConsumed,
                "point_x": point.x,
                "point_y": point.y,
                "resolved_point_x": resolvedPoint?.x ?? -1,
                "resolved_point_y": resolvedPoint?.y ?? -1,
                "suppress_path_hover": suppressCommandPathHover
            ]
            for (key, value) in runtimeDebugResolutionPayload(resolution) {
                payload[key] = value
            }
            runtimeDebugLog(
                hypothesisID: "h3",
                name: "command_click_release",
                expected: "ghostty-consumed clicks should only skip fallback for real ghostty targets",
                actual: "consumed_quicklook_resolution_skipped",
                data: payload
            )
#endif
            return nil
        }

        #if DEBUG
        cmuxDebugLog(
            "link.wordFallback resolved=\(resolution.path) source=\(resolution.source.rawValue) consumed=\(ghosttyConsumed ? 1 : 0)"
        )
        var payload: [String: Any] = [
            "flags": debugModifierString(modifierFlags),
            "ghostty_consumed": ghosttyConsumed,
            "point_x": point.x,
            "point_y": point.y,
            "resolved_point_x": resolvedPoint?.x ?? -1,
            "resolved_point_y": resolvedPoint?.y ?? -1,
            "suppress_path_hover": suppressCommandPathHover
        ]
        for (key, value) in runtimeDebugResolutionPayload(resolution) {
            payload[key] = value
        }
        runtimeDebugLog(
            hypothesisID: resolution.source == .snapshot ? "h3" : "h2",
            name: "command_click_release",
            expected: "cmd-click should open the resolved path",
            actual: "opening_resolved_path",
            data: payload
        )
        #endif

        // Remote-surface guard runs before shouldRoute so we never stat a local
        // path on the main thread for a remote workspace. When the cmux route
        // is applicable but split creation fails, fall back to the preferred
        // editor so the click never silently no-ops.
        if let termSurface = terminalSurface,
           let workspace = termSurface.owningWorkspace(),
           !workspace.isRemoteTerminalSurface(termSurface.id),
           CommandClickFileOpenRouter.openInCmux(
               workspace: workspace,
               sourcePanelId: termSurface.id,
               filePath: resolution.path
           ) {
            return resolution
        }

        PreferredEditorService(defaults: .standard).open(URL(fileURLWithPath: resolution.path))
        return resolution
    }

    private func clampedDebugPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, 1), max(bounds.width - 1, 1)),
            y: min(max(point.y, 1), max(bounds.height - 1, 1))
        )
    }

#if DEBUG
    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        guard let surface else { return false }
        let start = clampedDebugPoint(startPoint)
        let end = clampedDebugPoint(endPoint)
        let mods = GHOSTTY_MODS_NONE

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, start.x, bounds.height - start.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)

        let steps = max(4, Int(max(abs(end.x - start.x), abs(end.y - start.y)) / max(cellSize.width, 1)))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = NSPoint(
                x: start.x + ((end.x - start.x) * progress),
                y: start.y + ((end.y - start.y) * progress)
            )
            let clampedIntermediatePoint = clampedDebugPoint(intermediatePoint)
            ghostty_surface_mouse_pos(
                surface,
                clampedIntermediatePoint.x,
                bounds.height - clampedIntermediatePoint.y,
                mods
            )
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        return ghostty_surface_has_selection(surface)
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        guard let surface else { return false }
        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )
        return suppressCommandPathHover
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: flags)

        ghostty_surface_mouse_pos(
            surface,
            clampedPoint.x,
            bounds.height - clampedPoint.y,
            hoverModsFromFlags(
                flags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )

        let resolution = suppressCommandPathHover ? nil : resolveWordUnderCursorPath(at: clampedPoint)
        updateWordPathHover(
            at: clampedPoint,
            cmdHeld: true,
            suppressPathHover: suppressCommandPathHover
        )

        var payload: [String: Any] = [
            "hoverActive": wordPathHoverActive ? "1" : "0",
            "suppressed": suppressCommandPathHover ? "1" : "0"
        ]
        if let resolution {
            payload["resolvedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let flags: NSEvent.ModifierFlags = [.command]
        let mods = mouseModsFromFlags(flags)

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, mods)
        let pressHandled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        let releaseConsumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        let resolution = handleCommandClickRelease(
            at: clampedPoint,
            modifierFlags: flags,
            ghosttyConsumed: releaseConsumed
        )

        var payload: [String: Any] = [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": releaseConsumed ? "1" : "0",
        ]
        if let resolution {
            payload["openedPath"] = resolution.path
            payload["resolutionSource"] = resolution.source.rawValue
            payload["rawToken"] = resolution.rawToken
        }
        return payload
    }

    func debugSimulateStationaryCommandClick(at point: NSPoint) -> [String: Any] {
        guard let surface else {
            return ["error": "Missing surface"]
        }

        let clampedPoint = clampedDebugPoint(point)
        let noMods = GHOSTTY_MODS_NONE
        let flags: NSEvent.ModifierFlags = [.command]
        let commandMods = mouseModsFromFlags(flags)

        // Drive the production flagsChanged override for the Cmd press and
        // release so the regression covers the real modifier-transition path:
        // that handler is what refreshes ghostty link state under a stationary
        // pointer (ghostty ignores a same-cell mouse_pos with new mods), so a
        // helper that synthesized the forwarding itself would keep passing
        // with the handler broken.
        guard let cmdDown = debugFlagsChangedEvent(commandDown: true, at: clampedPoint),
              let cmdUp = debugFlagsChangedEvent(commandDown: false, at: clampedPoint) else {
            return ["error": "Failed to construct flagsChanged events"]
        }

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, noMods)
        flagsChanged(with: cmdDown)
        let pressHandled = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, commandMods)
        let releaseConsumed = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, commandMods)
        flagsChanged(with: cmdUp)

        return [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": releaseConsumed ? "1" : "0",
        ]
    }

    private func debugFlagsChangedEvent(commandDown: Bool, at pointInView: NSPoint) -> NSEvent? {
        // ghostty_input_action_e.modifierActionForFlagsChanged distinguishes left-Cmd
        // presses by the device-side bit, so a bare .command is read as a
        // release.
        let rawFlags: UInt = commandDown
            ? (NSEvent.ModifierFlags.command.rawValue | UInt(NX_DEVICELCMDKEYMASK))
            : 0
        return NSEvent.keyEvent(
            with: .flagsChanged,
            location: convert(pointInView, to: nil),
            modifierFlags: NSEvent.ModifierFlags(rawValue: rawFlags),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_Command)
        )
    }
#endif

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            requestPointerFocusRecovery()
            super.rightMouseDown(with: event)
            return
        }

        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mouseModsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mouseModsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mouseModsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mouseModsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mouseModsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mouseModsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, mouseModsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mouseModsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.triggerFlash", defaultValue: "Trigger Flash"),
                action: #selector(triggerFlash(_:)),
                keyEquivalent: ""
            )
            flashItem.target = self
            menu.addItem(.separator())
        }
        if hasCopyableTerminalSelection(surface: surface) {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copy", defaultValue: "Copy"),
                action: #selector(copy(_:)),
                keyEquivalent: ""
            )
            item.target = self
        }
        let pasteItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self
        menu.addItem(.separator())
        let splitHorizontallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitHorizontally", defaultValue: "Split Horizontally"),
            action: #selector(splitHorizontally(_:)),
            keyEquivalent: ""
        )
        splitHorizontallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitDown), to: splitHorizontallyItem)
        splitHorizontallyItem.image = NSImage(
            systemSymbolName: "rectangle.bottomhalf.inset.filled",
            accessibilityDescription: nil
        )

        let splitVerticallyItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.splitVertically", defaultValue: "Split Vertically"),
            action: #selector(splitVertically(_:)),
            keyEquivalent: ""
        )
        splitVerticallyItem.target = self
        applyConfiguredMenuShortcut(KeyboardShortcutSettings.menuShortcut(for: .splitRight), to: splitVerticallyItem)
        splitVerticallyItem.image = NSImage(
            systemSymbolName: "rectangle.righthalf.inset.filled",
            accessibilityDescription: nil
        )
        appendCurrentSurfaceContextMenuItems(to: menu)
        let resetTerminalItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.resetTerminal", defaultValue: "Reset Terminal"),
            action: #selector(resetTerminal(_:)),
            keyEquivalent: ""
        )
        resetTerminalItem.target = self
        resetTerminalItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.2.clockwise",
            accessibilityDescription: nil
        )
        appendReconnectRemotePaneMenuItem(to: menu)
        if terminalSurface != nil {
            menu.addItem(.separator())
            let identifiersItem = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                action: #selector(copyWorkspaceAndSurfaceIdentifiers(_:)),
                keyEquivalent: ""
            )
            identifiersItem.target = self
            let linkItem = menu.addItem(
                withTitle: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                action: #selector(copyCurrentSurfaceLink(_:)),
                keyEquivalent: ""
            )
            linkItem.target = self
        }
        return menu
    }

    private func canSplitCurrentSurface() -> Bool {
        guard let surfaceId = terminalSurface?.id else { return false }
        // Mirror panes are not workspace panels, but their split command routes
        // to tmux and the resulting layout change rebuilds the mirrored panes.
        if AppDelegate.shared?.remoteTmuxController.isMirrorPaneSurface(surfaceId) == true {
            return true
        }
        guard let tabId,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager,
              let workspace = manager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }
        return workspace.panels[surfaceId] != nil
    }

    @objc private func splitHorizontally(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .down)
    }

    @objc private func splitVertically(_ sender: Any?) {
        _ = splitCurrentSurface(direction: .right)
    }

    @discardableResult
    private func splitCurrentSurface(direction: SplitDirection) -> Bool {
        guard let surfaceId = terminalSurface?.id else { return false }
        // Remote tmux mirror pane: never fall through to a local split. The tmux
        // command either reaches the live stream, or the action reports false.
        if let controller = AppDelegate.shared?.remoteTmuxController,
           controller.isMirrorPaneSurface(surfaceId) {
            return controller.handleMirrorSplitRequested(surfaceId: surfaceId, vertical: !direction.isHorizontal)
        }
        guard let tabId,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else {
            return false
        }
        return manager.createSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    @objc private func resetTerminal(_ sender: Any?) {
        _ = performBindingAction("reset")
    }
    override func mouseMoved(with event: NSEvent) {
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            eventPoint.x,
            bounds.height - eventPoint.y,
            hoverModsFromFlags(
                event.modifierFlags,
                suppressCommandPathHover: suppressCommandPathHover
            )
        )
        updateWordPathHover(
            at: eventPoint,
            cmdHeld: event.modifierFlags.contains(.command),
            suppressPathHover: suppressCommandPathHover
        )
    }

    private func maybeRequestFirstResponderForMouseFocus() {
        guard let window else { return }
        let alreadyFirstResponder = window.firstResponder === self
        let shouldRequest = Self.shouldRequestFirstResponderForMouseFocus(
            focusFollowsMouseEnabled: GhosttyApp.shared.focusFollowsMouseEnabled(),
            pressedMouseButtons: NSEvent.pressedMouseButtons,
            appIsActive: NSApp.isActive,
            windowIsKey: window.isKeyWindow,
            alreadyFirstResponder: alreadyFirstResponder,
            visibleInUI: isVisibleInUI,
            hasUsableGeometry: hasUsableFocusGeometry,
            hiddenInHierarchy: isHiddenOrHasHiddenAncestor
        )
        guard shouldRequest else { return }
        window.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, mouseModsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let eventPoint = convert(event.locationInWindow, from: nil)
        trackMousePointIfUsable(eventPoint)
        // Forward the raw drag coordinates, including out-of-bounds positions.
        // Selection auto-scroll depends on libghostty observing the pointer leave
        // the viewport rather than a cached in-bounds hover point.
        ghostty_surface_mouse_pos(surface, eventPoint.x, bounds.height - eventPoint.y, mouseModsFromEvent(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        // Forward right-button drags so mouse-reporting apps receive pointer
        // motion while the right button is held. Without this, tmux's
        // right-click context menu (press to open, drag to highlight, release
        // to select) never sees the drag and cannot track hover state. Mirrors
        // mouseDragged and matches upstream Ghostty, which funnels every drag
        // variant to the same position-forwarding path.
        mouseDragged(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        // Only the middle button (buttonNumber 2) is forwarded to Ghostty, to
        // stay consistent with otherMouseDown/otherMouseUp above.
        guard event.buttonNumber == 2 else {
            super.otherMouseDragged(with: event)
            return
        }
        mouseDragged(with: event)
    }

#if DEBUG
    func debugHasPendingLeftMouseReleaseForTesting() -> Bool {
        hasPendingLeftMouseRelease
    }
#endif

    override func scrollWheel(with event: NSEvent) {
        NotificationCenter.default.post(name: .ghosttyDidReceiveWheelScroll, object: self)
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if Self.shouldDoublePreciseScrollDelta(for: event) {
            x *= 2
            y *= 2
        }
        scrollSpeedAccumulator.apply(x: &x, y: &y, precision: precision)
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

        // Track scroll state for lag detection
        let hasMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
        let momentumEnded = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        GhosttyApp.shared.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
#if DEBUG
        cmuxDebugLog(
            "surface.view.deinit view=\(Unmanaged.passUnretained(self).toOpaque()) " +
            "surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0)"
        )
#endif
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        keyboardCopyModeViewportJumpSyncExpirationTimer?.invalidate()
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

        if let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    fileprivate static func escapeDropForShell(_ value: String) -> String {
        TerminalImageTransferPlanner.escapeForShell(value)
    }

    static func dropPlanForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool
    ) -> DropPlan {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        switch TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        ) {
        case .insertText(let text):
            return .insertText(text)
        case .insertTextSegments(let segments, _):
            return .insertText(segments.joined())
        case .uploadFiles(let fileURLs, _):
            return .uploadFiles(fileURLs)
        case .reject:
            return .reject
        }
    }

    static func performRemoteDropUploadForTesting(
        upload: (@escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        upload { result in
            switch result {
            case .success(let remotePaths):
                let content = remotePaths
                    .map { Self.escapeDropForShell($0) }
                    .joined(separator: " ")
                guard !content.isEmpty else {
                    onFailure()
                    return
                }
                sendText(content)
            case .failure:
                onFailure()
            }
        }
    }

    @discardableResult
    static func handleDropForTesting(
        pasteboard: NSPasteboard,
        isRemoteTerminalSurface: Bool,
        uploadRemote: ([URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        sendText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool {
        let target: TerminalImageTransferTarget = isRemoteTerminalSurface ? .remote(.workspaceRemote) : .local
        let plan = TerminalImageTransferPlanner.plan(
            pasteboard: pasteboard,
            mode: .drop,
            target: target
        )
        guard plan != .reject else { return false }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            uploadWorkspaceRemote: { urls, _, finish in
                uploadRemote(urls) { result in
                    finish(result)
                    GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(urls)
                }
            },
            uploadDetectedSSH: { _, _, _, finish in
                finish(.failure(NSError(domain: "cmux.remote.drop", code: 4)))
            },
            insertText: sendText,
            onFailure: { _ in onFailure() }
        )
        return true
    }

    private func executeImageTransferPlan(
        _ plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        onCancel: @escaping () -> Void = {}
    ) -> Bool {
        guard plan != .reject else { return false }

        let operation = operation ?? {
            if case .uploadFiles = plan {
                return TerminalImageTransferOperation()
            }
            return nil
        }()

        if let operation {
            terminalSurface?.hostedView.beginImageTransferIndicator(
                for: operation,
                onCancel: onCancel
            )
        }

        if let operation, handleCustomDropUploadIfMatched(plan: plan, operation: operation) {
            return true
        }

        TerminalImageTransferPlanner.execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: { [weak self] fileURLs, operation, finish in
                guard let workspace = MainActor.assumeIsolated({
                    self?.terminalSurface?.owningWorkspace()
                }) else {
                    finish(.failure(NSError(domain: "cmux.remote.drop", code: 3)))
                    GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                    return
                }
                workspace.uploadDroppedFilesForRemoteTerminal(
                    fileURLs,
                    operation: operation,
                    completion: { result in
                        finish(result)
                        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                    }
                )
            },
            uploadDetectedSSH: { session, fileURLs, operation, finish in
                session.uploadDroppedFiles(
                    fileURLs,
                    operation: operation,
                    completion: { result in
                        finish(result)
                        GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
                    }
                )
            },
            insertText: { [weak self] text in
                let send = {
                    if let operation {
                        self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                    }
                    self?.deliverUploadResultText(text)
                }
                if Thread.isMainThread {
                    send()
                } else {
                    DispatchQueue.main.async(execute: send)
                }
            },
            onFailure: { [weak self] _ in
                if let operation {
                    self?.terminalSurface?.hostedView.endImageTransferIndicator(for: operation)
                }
                DispatchQueue.main.async {
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("terminal.remoteDropUpload.failed surface=\(self?.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
                }
            }
        )
        return true
    }

    private func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        MainActor.assumeIsolated {
            terminalSurface?.resolvedImageTransferTarget() ?? .local
        }
    }

    func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
        executePreparedImageTransfer(
            .fileURLs(urls),
            onCancel: {}
        )
    }

    @discardableResult
    fileprivate func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        executePreparedImageTransfer(
            TerminalImageTransferPlanner.prepare(
                pasteboard: pasteboard,
                mode: .drop
            ),
            onCancel: {}
        )
    }

    @discardableResult
    private func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        onCancel: @escaping () -> Void
    ) -> Bool {
        switch preparedContent {
        case .reject:
            return false
        case .insertText(let text):
            terminalSurface?.sendText(text)
            return true
        case .fileURLs(let fileURLs):
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: fileURLs,
                target: resolvedImageTransferTarget(),
                mode: .drop
            )
            return executeImageTransferPlan(plan, onCancel: onCancel)
        }
    }

#if DEBUG
    fileprivate enum DebugDropPayloadKind {
        case fileURLs
        case imageData
    }

    @discardableResult
    fileprivate func debugSimulateFileDrop(
        paths: [String],
        asImageData: Bool = false
    ) -> Bool {
        guard !paths.isEmpty else { return false }
        let pbName = NSPasteboard.Name("cmux.debug.drop.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pbName)
        pasteboard.clearContents()
        switch asImageData ? DebugDropPayloadKind.imageData : .fileURLs {
        case .fileURLs:
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            pasteboard.writeObjects(urls)
        case .imageData:
            let items = paths.compactMap { path -> NSPasteboardItem? in
                let url = URL(fileURLWithPath: path)
                guard let data = try? Data(contentsOf: url),
                      let type = debugImagePasteboardType(for: url) else { return nil }
                let item = NSPasteboardItem()
                item.setData(data, forType: type)
                return item
            }
            guard items.count == paths.count else { return false }
            pasteboard.writeObjects(items)
        }
        return insertDroppedPasteboard(pasteboard)
    }

    private func debugImagePasteboardType(for url: URL) -> NSPasteboard.PasteboardType? {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let utType = UTType(filenameExtension: pathExtension),
              utType.conforms(to: .image) else { return nil }
        return NSPasteboard.PasteboardType(utType.identifier)
    }

    fileprivate func debugRegisteredDropTypes() -> [String] {
        (registeredDraggedTypes ?? []).map(\.rawValue)
    }
#endif

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingEntered surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        // Defer to bonsplit when a tab/session drag is in flight: bonsplit's pane
        // drop overlays should win over the terminal's text/file drop handling.
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        #if DEBUG
        let types = sender.draggingPasteboard.types ?? []
        cmuxDebugLog("terminal.draggingUpdated surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") types=\(types.map(\.rawValue))")
        #endif
        guard let types = sender.draggingPasteboard.types else { return [] }
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return []
        }
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.tabTransferPasteboardType) || types.contains(Self.sidebarTabReorderPasteboardType) {
            return false
        }
        #if DEBUG
        cmuxDebugLog("terminal.fileDrop surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
        #endif
        return insertDroppedPasteboard(sender.draggingPasteboard)
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}

extension Notification.Name {
    static let ghosttyDidTick = Notification.Name("ghosttyDidTick")
    static let ghosttyDidRenderFrame = Notification.Name("ghosttyDidRenderFrame")
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttyDidReceiveWheelScroll = Notification.Name("ghosttyDidReceiveWheelScroll")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")
    static let ghosttyDefaultBackgroundDidChange = Notification.Name("ghosttyDefaultBackgroundDidChange")
    static let browserSearchFocus = Notification.Name("browserSearchFocus")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    // Keep keyboard routing on the terminal surface; this wrapper is viewport plumbing.
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        // Route wheel gestures to the terminal surface so Ghostty handles scrollback.
        // Letting NSScrollView consume these events moves the wrapper viewport itself,
        // which causes pane-content drift instead of terminal scrollback movement.
        GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: surface scroll")
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }
}

private final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class TerminalViewportBorderOverlayView: NSView {
    var effectiveSize: CGSize? {
        didSet { needsDisplay = true }
    }

    var drawsVisibleAreaBorder = false {
        didSet { needsDisplay = true }
    }
    var drawsVisibleAreaRightBorder = false {
        didSet { needsDisplay = true }
    }
    var drawsVisibleAreaBottomBorder = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard drawsVisibleAreaBorder,
              let effectiveSize,
              effectiveSize.width > 1,
              effectiveSize.height > 1 else {
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(1, scale)
        let width = min(effectiveSize.width, bounds.width)
        let height = min(effectiveSize.height, bounds.height)
        guard width > lineWidth, height > lineWidth else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        let x = width - lineWidth / 2
        let y = height - lineWidth / 2
        if drawsVisibleAreaRightBorder {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: y))
        }
        if drawsVisibleAreaBottomBorder {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: x, y: y))
        }
        // Stroke the exact window-chrome separator color used by the pane outline,
        // sidebar trailing edge, and tab-bar separators (one source of truth), so the
        // iOS-connected viewport border is pixel-identical to every other border in the
        // app instead of the previous hardcoded near-white separator stroke.
        WindowChromeColorResolver()
            .separatorColor(forChromeBackground: GhosttyBackgroundTheme.currentColor())
            .setStroke()
        path.stroke()
    }
}

final class GhosttySurfaceScrollView: NSView {
    enum FlashStyle {
        case navigation
        case notification
    }

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> FlashStyle {
        switch reason {
        case .navigation:
            return .navigation
        case .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return .notification
        }
    }

    private static func flashPresentation(for style: FlashStyle) -> WorkspaceAttentionFlashPresentation {
        switch style {
        case .navigation:
            return WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        case .notification:
            return WorkspaceAttentionCoordinator.flashStyle(for: .notificationArrival)
        }
    }

    private enum NotificationRingMetrics {
        static let inset = PanelOverlayRingMetrics.inset
        static let cornerRadius = PanelOverlayRingMetrics.cornerRadius
        static let lineWidth = PanelOverlayRingMetrics.lineWidth
    }

    private var sharedBackdropCutoutView: NSView?
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let mobileViewportBorderOverlayView = TerminalViewportBorderOverlayView(frame: .zero)
    private let inactiveOverlayView: GhosttyFlashOverlayView
    private let dropZoneOverlayView: GhosttyFlashOverlayView
    private let paneDropTargetView = TerminalPaneDropTargetView(frame: .zero)
    private let notificationRingOverlayView: GhosttyFlashOverlayView
    private let notificationRingLayer: CAShapeLayer
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    var isRightSidebarDockSurface: Bool {
        surfaceView.terminalSurface?.focusPlacement == .rightSidebarDock
    }

    var uiWindow: NSWindow? {
        if let terminalSurface = surfaceView.terminalSurface {
            return terminalSurface.uiWindow
        }
        return window
    }

    func forwardKeyDownToSurface(_ event: NSEvent) {
        surfaceView.keyDown(with: event)
    }

    private var lastFlashStyle: FlashStyle = .navigation
    private let keyboardCopyModeBadgeContainerView: GhosttyFlashOverlayView
    private let keyboardCopyModeBadgeView: GhosttyPassthroughVisualEffectView
    private let keyboardCopyModeBadgeIconView: NSImageView
    private let keyboardCopyModeBadgeLabel: NSTextField
    private let imageTransferIndicatorContainerView: NSView
    private let imageTransferIndicatorView: NSVisualEffectView
    private let imageTransferIndicatorSpinner: NSProgressIndicator
    private let imageTransferCancelButton: NSButton
    private var searchOverlayHostingView: NSHostingView<SurfaceSearchOverlay>?
    private var deferredSearchOverlayMutationWorkItem: DispatchWorkItem?
    private var imageTransferIndicatorShowWorkItem: DispatchWorkItem?
    private var activeImageTransferOperation: TerminalImageTransferOperation?
    private var activeImageTransferCancelHandler: (() -> Void)?
    private var lastSearchOverlayStateID: ObjectIdentifier?
    private var searchOverlayMutationGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollbarTrackingArea: NSTrackingArea?
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    /// Tracks whether the user has scrolled away from the bottom to review scrollback.
    /// When true, auto-scroll should be suspended to prevent the "doomscroll" bug
    /// where the terminal fights the user's scroll position.
    private var userScrolledAwayFromBottom = false
    private var pendingExplicitWheelScroll = false
    private var allowExplicitScrollbarSync = false
    /// Threshold in points from bottom to consider "at bottom" (allows for minor float drift)
    private static let scrollToBottomThreshold: CGFloat = 5.0
    private var isActive = true
    private var lastFocusRefreshAt: CFTimeInterval = 0
    private var lastRequestedPortalOcclusionVisible: Bool?
    private var activeDropZone: DropZone?
    private var pendingDropZone: DropZone?
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    private var pendingAutomaticFirstResponderApply = false
    private var pendingSuppressedFirstResponderFocusReapply = false
    // Hidden/tiny focus retry is bounded by layout/visibility signals, not a timer loop.

    /// Tracks whether keyboard focus should go to the search field or the terminal
    /// when the window becomes key while the find bar is open.
    enum SearchFocusTarget {
        case searchField
        case terminal
    }
    private(set) var searchFocusTarget: SearchFocusTarget = .searchField


#if DEBUG
    private var lastDropZoneOverlayLogSignature: String?
    private var lastDragGeometryLogSignature: String?
    private var dragLayoutLogSequence: UInt64 = 0
    private static let tabTransferPasteboardType = NSPasteboard.PasteboardType("com.splittabbar.tabtransfer")
    private static let sidebarTabReorderPasteboardType = NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder")
    private static var flashCounts: [UUID: Int] = [:]
    private static var drawCounts: [UUID: Int] = [:]
    private static var lastDrawTimes: [UUID: CFTimeInterval] = [:]
    private static var presentCounts: [UUID: Int] = [:]
    private static var dropOverlayShowCounts: [UUID: Int] = [:]
    private static var lastPresentTimes: [UUID: CFTimeInterval] = [:]
    private static var lastContentsKeys: [UUID: String] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }

    static func drawStats(for surfaceId: UUID) -> (count: Int, last: CFTimeInterval) {
        (drawCounts[surfaceId, default: 0], lastDrawTimes[surfaceId, default: 0])
    }

    static func resetDrawStats() {
        drawCounts.removeAll()
        lastDrawTimes.removeAll()
    }

    static func recordSurfaceDraw(_ surfaceId: UUID) {
        drawCounts[surfaceId, default: 0] += 1
        lastDrawTimes[surfaceId] = CACurrentMediaTime()
    }

    private static func contentsKey(for layer: CALayer?) -> String {
        guard let modelLayer = layer else { return "nil" }
        // Prefer the presentation layer to better reflect what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return "nil" }
        // Prefer pointer identity for object/CFType contents.
        if let obj = contents as AnyObject? {
            let ptr = Unmanaged.passUnretained(obj).toOpaque()
            var key = "0x" + String(UInt(bitPattern: ptr), radix: 16)

            // For IOSurface-backed terminal layers, the IOSurface object can remain stable while
            // its contents change. Include the IOSurface seed so "new frame rendered" is visible
            // to debug/test tooling even when the pointer identity doesn't change.
            let cf = contents as CFTypeRef
            if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                let surfaceRef = (contents as! IOSurfaceRef)
                let seed = IOSurfaceGetSeed(surfaceRef)
                key += ":seed=\(seed)"
            }

            return key
        }
        return String(describing: contents)
    }

    private static func updatePresentStats(surfaceId: UUID, layer: CALayer?) -> (count: Int, last: CFTimeInterval, key: String) {
        let key = contentsKey(for: layer)
        if lastContentsKeys[surfaceId] != key {
            presentCounts[surfaceId, default: 0] += 1
            lastPresentTimes[surfaceId] = CACurrentMediaTime()
            lastContentsKeys[surfaceId] = key
        }
        return (presentCounts[surfaceId, default: 0], lastPresentTimes[surfaceId, default: 0], key)
    }

    private func recordDropOverlayShowAnimation() {
        guard let surfaceId = surfaceView.terminalSurface?.id else { return }
        Self.dropOverlayShowCounts[surfaceId, default: 0] += 1
    }

    func debugProbeDropOverlayAnimation(useDeferredPath: Bool) -> (before: Int, after: Int, bounds: CGSize) {
        guard let surfaceId = surfaceView.terminalSurface?.id else {
            return (0, 0, bounds.size)
        }

        let before = Self.dropOverlayShowCounts[surfaceId, default: 0]

        // Reset to a hidden baseline so each probe exercises an initial-show transition.
        dropZoneOverlayAnimationGeneration &+= 1
        activeDropZone = nil
        pendingDropZone = nil
        dropZoneOverlayView.layer?.removeAllAnimations()
        dropZoneOverlayView.isHidden = true
        dropZoneOverlayView.alphaValue = 1

        if useDeferredPath {
            pendingDropZone = .left
            synchronizeGeometryAndContent()
        } else {
            setDropZoneOverlay(zone: .left)
        }

        let after = Self.dropOverlayShowCounts[surfaceId, default: 0]
        setDropZoneOverlay(zone: nil)
        return (before, after, bounds.size)
    }

    var debugSurfaceId: UUID? {
        surfaceView.terminalSurface?.id
    }

    var debugCellSize: CGSize {
        surfaceView.cellSize
    }

    private func debugPointInSurface(_ point: NSPoint) -> NSPoint {
        surfaceView.convert(point, from: self)
    }

    func debugSimulateSelection(from startPoint: NSPoint, to endPoint: NSPoint) -> Bool {
        surfaceView.debugSimulateSelection(
            from: debugPointInSurface(startPoint),
            to: debugPointInSurface(endPoint)
        )
    }

    func debugSimulateCommandHover(at point: NSPoint) -> Bool {
        surfaceView.debugSimulateCommandHover(at: debugPointInSurface(point))
    }

    func debugSimulateCommandHoverDetails(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateCommandHoverDetails(at: debugPointInSurface(point))
    }

    func debugSimulateCommandClick(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateCommandClick(at: debugPointInSurface(point))
    }

    func debugSimulateStationaryCommandClick(at point: NSPoint) -> [String: Any] {
        surfaceView.debugSimulateStationaryCommandClick(at: debugPointInSurface(point))
    }
#endif

    func portalBindingGuardState() -> (surfaceId: UUID?, generation: UInt64?, state: String) {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return (surfaceId: nil, generation: nil, state: "missingSurface")
        }
        return (
            surfaceId: terminalSurface.id,
            generation: terminalSurface.portalBindingGeneration(),
            state: terminalSurface.portalBindingStateLabel()
        )
    }

    func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        return terminalSurface.canAcceptPortalBinding(
            expectedSurfaceId: expectedSurfaceId,
            expectedGeneration: expectedGeneration
        )
    }

    func releaseOwnedPortalHost(hostId: ObjectIdentifier, reason: String) {
        surfaceView.terminalSurface?.releasePortalHostIfOwned(
            hostId: hostId,
            reason: reason
        )
    }

    func prepareOwnedPortalHostForTransientReattach(hostId: ObjectIdentifier, reason: String) {
        surfaceView.terminalSurface?.preparePortalHostReplacementIfOwned(
            hostId: hostId,
            reason: reason
        )
    }

    init(surfaceView: GhosttyNSView) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        inactiveOverlayView = GhosttyFlashOverlayView(frame: .zero)
        dropZoneOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingLayer = CAShapeLayer()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        keyboardCopyModeBadgeContainerView = GhosttyFlashOverlayView(frame: .zero)
        keyboardCopyModeBadgeView = GhosttyPassthroughVisualEffectView(frame: .zero)
        keyboardCopyModeBadgeIconView = NSImageView(frame: .zero)
        keyboardCopyModeBadgeLabel = NSTextField(labelWithString: terminalKeyboardCopyModeIndicatorText)
        imageTransferIndicatorContainerView = NSView(frame: .zero)
        imageTransferIndicatorView = NSVisualEffectView(frame: .zero)
        imageTransferIndicatorSpinner = NSProgressIndicator(frame: .zero)
        imageTransferCancelButton = NSButton(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        backgroundView.layer?.isOpaque = false
        addSubview(backgroundView)
        addSubview(scrollView)
        mobileViewportBorderOverlayView.isHidden = true
        addSubview(mobileViewportBorderOverlayView, positioned: .above, relativeTo: scrollView)
        paneDropTargetView.hostedView = self
        addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        synchronizeScrollbarAppearance()
        inactiveOverlayView.wantsLayer = true
        inactiveOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        inactiveOverlayView.isHidden = true
        addSubview(inactiveOverlayView)
        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = cmuxAccentNSColor().withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = cmuxAccentNSColor().cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        notificationRingOverlayView.wantsLayer = true
        notificationRingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        notificationRingOverlayView.layer?.masksToBounds = false
        notificationRingOverlayView.autoresizingMask = [.width, .height]
        let notificationRingStyle = WorkspaceAttentionCoordinator.notificationRingStyle
        let notificationRingColor = notificationRingStyle.accent.strokeColor
        notificationRingLayer.fillColor = NSColor.clear.cgColor
        notificationRingLayer.strokeColor = notificationRingColor.cgColor
        notificationRingLayer.lineWidth = NotificationRingMetrics.lineWidth
        notificationRingLayer.lineJoin = .round
        notificationRingLayer.lineCap = .round
        notificationRingLayer.shadowColor = notificationRingColor.cgColor
        notificationRingLayer.shadowOpacity = Float(notificationRingStyle.glowOpacity)
        notificationRingLayer.shadowRadius = notificationRingStyle.glowRadius
        notificationRingLayer.shadowOffset = .zero
        notificationRingLayer.opacity = 0
        notificationRingOverlayView.layer?.addSublayer(notificationRingLayer)
        notificationRingOverlayView.isHidden = true
        addSubview(notificationRingOverlayView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        let flashStyle = WorkspaceAttentionCoordinator.flashStyle(for: .navigation)
        let flashColor = flashStyle.accent.strokeColor
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = flashColor.cgColor
        flashLayer.lineWidth = NotificationRingMetrics.lineWidth
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = flashColor.cgColor
        flashLayer.shadowOpacity = Float(flashStyle.glowOpacity)
        flashLayer.shadowRadius = flashStyle.glowRadius
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)
        keyboardCopyModeBadgeContainerView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeContainerView.wantsLayer = true
        keyboardCopyModeBadgeContainerView.layer?.masksToBounds = false
        keyboardCopyModeBadgeContainerView.layer?.shadowColor = NSColor.black.cgColor
        keyboardCopyModeBadgeContainerView.layer?.shadowOpacity = 0.22
        keyboardCopyModeBadgeContainerView.layer?.shadowRadius = 10
        keyboardCopyModeBadgeContainerView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        keyboardCopyModeBadgeView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeView.wantsLayer = true
        keyboardCopyModeBadgeView.material = .hudWindow
        keyboardCopyModeBadgeView.blendingMode = .withinWindow
        keyboardCopyModeBadgeView.state = .active
        keyboardCopyModeBadgeView.layer?.cornerRadius = 18
        keyboardCopyModeBadgeView.layer?.masksToBounds = true
        keyboardCopyModeBadgeView.layer?.borderWidth = 1
        keyboardCopyModeBadgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        keyboardCopyModeBadgeView.alphaValue = 0.97
        keyboardCopyModeBadgeIconView.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeIconView.image = NSImage(
            systemSymbolName: "keyboard.badge.ellipsis",
            accessibilityDescription: terminalKeyTableIndicatorAccessibilityLabel
        )
        keyboardCopyModeBadgeIconView.contentTintColor = NSColor.secondaryLabelColor
        keyboardCopyModeBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        keyboardCopyModeBadgeLabel.textColor = NSColor.labelColor
        applyKeyboardCopyModeBadgeFonts()
        keyboardCopyModeBadgeLabel.lineBreakMode = .byTruncatingTail
        keyboardCopyModeBadgeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyboardCopyModeBadgeLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyboardCopyModeBadgeContainerView.addSubview(keyboardCopyModeBadgeView)
        keyboardCopyModeBadgeView.addSubview(keyboardCopyModeBadgeIconView)
        keyboardCopyModeBadgeView.addSubview(keyboardCopyModeBadgeLabel)
        NSLayoutConstraint.activate([
            keyboardCopyModeBadgeView.topAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.topAnchor),
            keyboardCopyModeBadgeView.bottomAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.bottomAnchor),
            keyboardCopyModeBadgeView.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.leadingAnchor),
            keyboardCopyModeBadgeView.trailingAnchor.constraint(equalTo: keyboardCopyModeBadgeContainerView.trailingAnchor),
            keyboardCopyModeBadgeView.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            keyboardCopyModeBadgeIconView.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeView.leadingAnchor, constant: 12),
            keyboardCopyModeBadgeIconView.centerYAnchor.constraint(equalTo: keyboardCopyModeBadgeView.centerYAnchor),
            keyboardCopyModeBadgeIconView.widthAnchor.constraint(equalToConstant: 18),
            keyboardCopyModeBadgeIconView.heightAnchor.constraint(equalToConstant: 18),
            keyboardCopyModeBadgeLabel.leadingAnchor.constraint(equalTo: keyboardCopyModeBadgeIconView.trailingAnchor, constant: 7),
            keyboardCopyModeBadgeLabel.trailingAnchor.constraint(equalTo: keyboardCopyModeBadgeView.trailingAnchor, constant: -14),
            keyboardCopyModeBadgeLabel.topAnchor.constraint(equalTo: keyboardCopyModeBadgeView.topAnchor, constant: 8),
            keyboardCopyModeBadgeLabel.bottomAnchor.constraint(equalTo: keyboardCopyModeBadgeView.bottomAnchor, constant: -8),
        ])
        keyboardCopyModeBadgeContainerView.isHidden = true
        addSubview(keyboardCopyModeBadgeContainerView)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: GlobalFontMagnification.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyKeyboardCopyModeBadgeFonts()
            }
        )
        NSLayoutConstraint.activate([
            keyboardCopyModeBadgeContainerView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            keyboardCopyModeBadgeContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        imageTransferIndicatorContainerView.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorContainerView.wantsLayer = true
        imageTransferIndicatorContainerView.layer?.masksToBounds = false
        imageTransferIndicatorContainerView.layer?.shadowColor = NSColor.black.cgColor
        imageTransferIndicatorContainerView.layer?.shadowOpacity = 0.18
        imageTransferIndicatorContainerView.layer?.shadowRadius = 8
        imageTransferIndicatorContainerView.layer?.shadowOffset = CGSize(width: 0, height: 2)
        imageTransferIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorView.wantsLayer = true
        imageTransferIndicatorView.material = .hudWindow
        imageTransferIndicatorView.blendingMode = .withinWindow
        imageTransferIndicatorView.state = .active
        imageTransferIndicatorView.layer?.cornerRadius = 16
        imageTransferIndicatorView.layer?.masksToBounds = true
        imageTransferIndicatorView.layer?.borderWidth = 1
        imageTransferIndicatorView.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        imageTransferIndicatorView.alphaValue = 0.95
        imageTransferIndicatorSpinner.translatesAutoresizingMaskIntoConstraints = false
        imageTransferIndicatorSpinner.style = .spinning
        imageTransferIndicatorSpinner.controlSize = .small
        imageTransferIndicatorSpinner.isDisplayedWhenStopped = false
        imageTransferCancelButton.translatesAutoresizingMaskIntoConstraints = false
        imageTransferCancelButton.isBordered = false
        imageTransferCancelButton.imagePosition = .imageOnly
        imageTransferCancelButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "common.cancel", defaultValue: "Cancel")
        )
        imageTransferCancelButton.contentTintColor = NSColor.secondaryLabelColor
        imageTransferCancelButton.toolTip = String(localized: "common.cancel", defaultValue: "Cancel")
        imageTransferCancelButton.setAccessibilityLabel(
            String(localized: "common.cancel", defaultValue: "Cancel")
        )
        imageTransferCancelButton.target = self
        imageTransferCancelButton.action = #selector(handleImageTransferCancel)
        imageTransferIndicatorContainerView.addSubview(imageTransferIndicatorView)
        imageTransferIndicatorView.addSubview(imageTransferIndicatorSpinner)
        imageTransferIndicatorView.addSubview(imageTransferCancelButton)
        NSLayoutConstraint.activate([
            imageTransferIndicatorView.topAnchor.constraint(equalTo: imageTransferIndicatorContainerView.topAnchor),
            imageTransferIndicatorView.bottomAnchor.constraint(equalTo: imageTransferIndicatorContainerView.bottomAnchor),
            imageTransferIndicatorView.leadingAnchor.constraint(equalTo: imageTransferIndicatorContainerView.leadingAnchor),
            imageTransferIndicatorView.trailingAnchor.constraint(equalTo: imageTransferIndicatorContainerView.trailingAnchor),
            imageTransferIndicatorSpinner.leadingAnchor.constraint(equalTo: imageTransferIndicatorView.leadingAnchor, constant: 10),
            imageTransferIndicatorSpinner.centerYAnchor.constraint(equalTo: imageTransferIndicatorView.centerYAnchor),
            imageTransferIndicatorSpinner.widthAnchor.constraint(equalToConstant: 14),
            imageTransferIndicatorSpinner.heightAnchor.constraint(equalToConstant: 14),
            imageTransferCancelButton.leadingAnchor.constraint(equalTo: imageTransferIndicatorSpinner.trailingAnchor, constant: 6),
            imageTransferCancelButton.trailingAnchor.constraint(equalTo: imageTransferIndicatorView.trailingAnchor, constant: -8),
            imageTransferCancelButton.centerYAnchor.constraint(equalTo: imageTransferIndicatorView.centerYAnchor),
            imageTransferCancelButton.widthAnchor.constraint(equalToConstant: 16),
            imageTransferCancelButton.heightAnchor.constraint(equalToConstant: 16),
            imageTransferIndicatorSpinner.topAnchor.constraint(equalTo: imageTransferIndicatorView.topAnchor, constant: 8),
            imageTransferIndicatorSpinner.bottomAnchor.constraint(equalTo: imageTransferIndicatorView.bottomAnchor, constant: -8),
        ])
        imageTransferIndicatorContainerView.isHidden = true
        addSubview(imageTransferIndicatorContainerView)
        NSLayoutConstraint.activate([
            imageTransferIndicatorContainerView.topAnchor.constraint(
                equalTo: keyboardCopyModeBadgeContainerView.bottomAnchor,
                constant: 8
            ),
            imageTransferIndicatorContainerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

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
            // Final scroll position check to update userScrolledAwayFromBottom state
            self?.handleLiveScroll()
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
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let readySurfaceId = notification.userInfo?["surfaceId"] as? UUID,
                  readySurfaceId == self.surfaceView.terminalSurface?.id else {
                return
            }
            // Session restore can request focus before the runtime surface exists.
            // Re-run the normal first-responder/focus path once the surface is live.
            guard self.isActive || self.surfaceView.desiredFocus || self.isSurfaceViewFirstResponder() else {
                return
            }
            self.scheduleAutomaticFirstResponderApply(reason: "surfaceDidBecomeReady")
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidReceiveWheelScroll,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.pendingExplicitWheelScroll = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttySearchFocus,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surface = notification.object as? TerminalSurface,
                  surface === self.surfaceView.terminalSurface else { return }
            self.searchFocusTarget = .searchField
            // Explicitly unfocus the terminal so the cursor stops blinking
            // when the search field takes over. The observer is registered with
            // `queue: .main`, so the @MainActor `setFocus` call is in fact
            // main-isolated.
            MainActor.assumeIsolated {
                surface.setFocus(false)
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            // Match AppKit's geometry change immediately so the terminal width
            // does not stay stuck behind a legacy scrollbar gutter.
            queue: nil
        ) { [weak self] _ in
            self?.handlePreferredScrollerStyleChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: TerminalScrollBarSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleTerminalScrollBarPreferenceChange()
        })

    }

    private func applyKeyboardCopyModeBadgeFonts() {
        keyboardCopyModeBadgeIconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(13),
            weight: .regular,
            scale: .medium
        )
        keyboardCopyModeBadgeLabel.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
#if DEBUG
        cmuxDebugLog(
            "surface.hosted.deinit surface=\(debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
            "inWindow=\(window != nil ? 1 : 0) hasSuperview=\(superview != nil ? 1 : 0) " +
            "hidden=\(isHidden ? 1 : 0) frame=\(String(format: "%.1fx%.1f", frame.width, frame.height))"
        )
#endif
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        deferredSearchOverlayMutationWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem?.cancel()
        dropZoneOverlayView.removeFromSuperview()
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Avoid stealing focus on scroll; focus is managed explicitly by the surface view.
    override var acceptsFirstResponder: Bool { false }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard scrollView.hasVerticalScroller,
              NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        if let scrollbarTrackingArea {
            removeTrackingArea(scrollbarTrackingArea)
            self.scrollbarTrackingArea = nil
        }

        super.updateTrackingAreas()

        guard scrollView.hasVerticalScroller,
              let scroller = scrollView.verticalScroller else { return }

        let trackingArea = NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        scrollbarTrackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        synchronizeGeometryAndContent()
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        bringPaneDropTargetToFrontIfNeeded()
        scheduleSuppressedFirstResponderFocusReapplyIfReady(
            reason: "becomeFirstResponder.hiddenOrTiny.layout"
        )
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard activeDropZone != nil || pendingDropZone != nil else { return }
        attachDropZoneOverlayIfNeeded()
        if let zone = activeDropZone ?? pendingDropZone {
            applyDropZoneOverlayFrame(dropZoneOverlayFrame(for: zone, in: bounds.size))
        }
    }

    /// Reconcile AppKit geometry with ghostty surface geometry synchronously.
    /// Used after split topology mutations (close/split) to prevent a stale one-frame
    /// IOSurface size from being presented after pane expansion.
    @discardableResult
    func reconcileGeometryNow() -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileGeometryNow()
            }
            return false
        }

        return synchronizeGeometryAndContent()
    }

    /// Request an immediate terminal redraw after geometry updates so stale IOSurface
    /// contents do not remain stretched during live resize churn.
    func refreshSurfaceNow(reason: String = "portal.refreshSurfaceNow") {
        // Portal reparent/reveal can settle geometry a tick before AppKit finishes
        // realizing the terminal subtree's backing layer state. Flush display for the
        // hosted subtree first so forceRefresh does not race a still-unrealized layer.
        layoutSubtreeIfNeeded()
        surfaceView.layoutSubtreeIfNeeded()
        displayIfNeeded()
        surfaceView.displayIfNeeded()
        surfaceView.terminalSurface?.forceRefresh(reason: reason)
    }

    @discardableResult
    private func synchronizeGeometryAndContent() -> Bool {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let didScrollbarAppearanceChange = synchronizeScrollbarAppearance()
        let previousSurfaceSize = surfaceView.frame.size
        if let sharedBackdropCutoutView {
            _ = setFrameIfNeeded(sharedBackdropCutoutView, to: bounds)
        }
        _ = setFrameIfNeeded(backgroundView, to: bounds)
        _ = setFrameIfNeeded(scrollView, to: bounds)
        let targetSize = scrollView.bounds.size
#if DEBUG
        logLayoutDuringActiveDrag(targetSize: targetSize)
#endif
        let targetSurfaceFrame = CGRect(origin: surfaceView.frame.origin, size: targetSize)
        _ = setFrameIfNeeded(surfaceView, to: targetSurfaceFrame)
        let targetDocumentFrame = CGRect(
            origin: documentView.frame.origin,
            size: CGSize(width: scrollView.bounds.width, height: documentView.frame.height)
        )
        _ = setFrameIfNeeded(documentView, to: targetDocumentFrame)
        _ = setFrameIfNeeded(mobileViewportBorderOverlayView, to: bounds)
        _ = setFrameIfNeeded(inactiveOverlayView, to: bounds)
        _ = setFrameIfNeeded(paneDropTargetView, to: bounds)
        if let zone = activeDropZone {
            attachDropZoneOverlayIfNeeded()
            _ = setFrameIfNeeded(
                dropZoneOverlayView,
                to: dropZoneOverlayFrame(for: zone, in: bounds.size)
            )
        }
        if let pending = pendingDropZone,
           bounds.width > 2,
           bounds.height > 2 {
            pendingDropZone = nil
#if DEBUG
            let frame = dropZoneOverlayFrame(for: pending, in: bounds.size)
            logDropZoneOverlay(event: "flushPending", zone: pending, frame: frame)
#endif
            // Reuse the normal show/update path so deferred overlays get the
            // same initial animation as direct drop-zone activation.
            setDropZoneOverlay(zone: pending)
        }
        _ = setFrameIfNeeded(notificationRingOverlayView, to: bounds)
        _ = setFrameIfNeeded(flashOverlayView, to: bounds)
        if let overlay = searchOverlayHostingView {
            _ = setFrameIfNeeded(overlay, to: bounds)
        }
        bringPaneDropTargetToFrontIfNeeded()
        // NSScrollView can defer clip-view/content-size updates until its own layout pass,
        // which makes interactive width changes arrive a queue turn late on Sequoia.
        if didScrollbarAppearanceChange {
            scrollView.tile()
        }
        scrollView.layoutSubtreeIfNeeded()
        updateNotificationRingPath()
        updateFlashPath(style: lastFlashStyle)
        updateFlashAppearance(style: lastFlashStyle)
        synchronizeScrollView()
        synchronizeSurfaceView()
        let didCoreSurfaceChange = synchronizeCoreSurface()
        return !sizeApproximatelyEqual(previousSurfaceSize, targetSize) || didCoreSurfaceChange
    }

    func setMobileViewportBorder(size: CGSize?, drawRight: Bool, drawBottom: Bool) {
        let isVisible = drawRight || drawBottom
        mobileViewportBorderOverlayView.effectiveSize = size
        mobileViewportBorderOverlayView.drawsVisibleAreaBorder = isVisible
        mobileViewportBorderOverlayView.drawsVisibleAreaRightBorder = drawRight
        mobileViewportBorderOverlayView.drawsVisibleAreaBottomBorder = drawBottom
        mobileViewportBorderOverlayView.isHidden = !isVisible
    }

    @discardableResult
    private func setFrameIfNeeded(_ view: NSView, to frame: CGRect) -> Bool {
        guard !Self.rectApproximatelyEqual(view.frame, frame) else { return false }
        view.frame = frame
        return true
    }

    private func sizeApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs.width - rhs.width) <= epsilon && abs(lhs.height - rhs.height) <= epsilon
    }

    private func pointApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.x - rhs.x) <= epsilon && abs(lhs.y - rhs.y) <= epsilon
    }

    private func dropZoneOverlayContainerView() -> NSView {
        superview ?? self
    }

    private func bringPaneDropTargetToFrontIfNeeded() {
        if paneDropTargetView.superview !== self || subviews.last !== paneDropTargetView {
            addSubview(paneDropTargetView, positioned: .above, relativeTo: nil)
        }
    }

    private func attachDropZoneOverlayIfNeeded() {
        // Keep the hover indicator outside the hosted terminal subtree so it stays purely additive
        // and cannot invalidate the scroll/surface layout that Ghostty renders into.
        let container = dropZoneOverlayContainerView()
        if dropZoneOverlayView.superview !== container {
            dropZoneOverlayView.removeFromSuperview()
            if container === self {
                addSubview(dropZoneOverlayView, positioned: .above, relativeTo: nil)
            } else {
                container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
            }
#if DEBUG
            logDropZoneOverlay(event: "attach", zone: activeDropZone ?? pendingDropZone, frame: dropZoneOverlayView.frame)
#endif
            return
        }

        guard container !== self else { return }
        guard let hostedIndex = container.subviews.firstIndex(of: self),
              let overlayIndex = container.subviews.firstIndex(of: dropZoneOverlayView),
              overlayIndex <= hostedIndex else { return }
        container.addSubview(dropZoneOverlayView, positioned: .above, relativeTo: self)
    }

    private func applyDropZoneOverlayFrame(_ frame: CGRect) {
        if Self.rectApproximatelyEqual(dropZoneOverlayView.frame, frame) { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropZoneOverlayView.frame = frame
        CATransaction.commit()
    }

#if DEBUG
    private static func isDragMouseEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private func hasActiveDragLoggingContext() -> Bool {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        return activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
    }

    private func logDragGeometryChange(event: String, old: CGPoint, new: CGPoint) {
        guard hasActiveDragLoggingContext() else { return }

        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let signature =
            "\(event)|\(surface)|\(String(format: "%.1f,%.1f", old.x, old.y))|" +
            "\(String(format: "%.1f,%.1f", new.x, new.y))|\(overlaySuperviewClass)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDragGeometryLogSignature != signature else { return }
        lastDragGeometryLogSignature = signature
        cmuxDebugLog(
            "terminal.dragGeometry event=\(event) surface=\(surface) " +
            "old=\(String(format: "%.1f,%.1f", old.x, old.y)) " +
            "new=\(String(format: "%.1f,%.1f", new.x, new.y)) " +
            "overlaySuper=\(overlaySuperviewClass) " +
            "overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "overlayHidden=\(dropZoneOverlayView.isHidden ? 1 : 0)"
        )
    }

    private func logLayoutDuringActiveDrag(targetSize: CGSize) {
        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        let hasActiveDrag =
            activeDropZone != nil ||
            pendingDropZone != nil ||
            ((hasTabDrag || hasSidebarDrag) && Self.isDragMouseEvent(eventType))
        guard hasActiveDrag else { return }

        dragLayoutLogSequence &+= 1
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let activeZone = activeDropZone.map { String(describing: $0) } ?? "none"
        let pendingZone = pendingDropZone.map { String(describing: $0) } ?? "none"
        let event = eventType.map { String(describing: $0) } ?? "nil"
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "terminal.layout.drag surface=\(surface) seq=\(dragLayoutLogSequence) " +
            "activeZone=\(activeZone) pendingZone=\(pendingZone) " +
            "hasTabDrag=\(hasTabDrag ? 1 : 0) hasSidebarDrag=\(hasSidebarDrag ? 1 : 0) " +
            "event=\(event) inWindow=\(window != nil ? 1 : 0) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(String(format: "%.1f,%.1f", scrollView.contentView.bounds.origin.x, scrollView.contentView.bounds.origin.y)) " +
            "surfaceOrigin=\(String(format: "%.1f,%.1f", surfaceView.frame.origin.x, surfaceView.frame.origin.y)) " +
            "bounds=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
            "target=\(String(format: "%.1fx%.1f", targetSize.width, targetSize.height))"
        )
    }
#endif

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
            // Registered with `queue: .main`, so the @MainActor `searchState`
            // reads below are in fact main-isolated.
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.surfaceView.isVisibleInUI, let tabId = self.surfaceView.tabId, let surfaceId = self.surfaceView.terminalSurface?.id, self.matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: surfaceId) else { return }
#if DEBUG
                cmuxDebugLog("find.window.didBecomeKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(self.surfaceView.terminalSurface?.searchState != nil) focusTarget=\(self.searchFocusTarget) firstResponder=\(String(describing: self.window?.firstResponder))")
#endif
                self.scheduleAutomaticFirstResponderApply(reason: "didBecomeKey")
            }
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Registered with `queue: .main`, so the @MainActor `searchState`
            // read below is in fact main-isolated.
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let searchActive = self.surfaceView.terminalSurface?.searchState != nil
                // Losing key window does not always trigger first-responder resignation, so force
                // the focused terminal view to yield responder to keep Ghostty cursor/focus state in sync.
                if let fr = window.firstResponder as? NSView,
                   fr === self.surfaceView || fr.isDescendant(of: self.surfaceView) {
#if DEBUG
                    cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) resigningFirstResponder")
#endif
                    window.makeFirstResponder(nil)
                } else {
#if DEBUG
                    cmuxDebugLog("find.window.didResignKey surface=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") searchActive=\(searchActive) firstResponder=\(String(describing: window.firstResponder)) (not terminal, skipping)")
#endif
                }
            }
        })
        if window.isKeyWindow {
            scheduleAutomaticFirstResponderApply(reason: "viewDidMoveToWindow")
        }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
        // Preserve the bootstrap 800x600 surface until portal reattach churn
        // has produced a real host size instead of a transient 1x1 placeholder.
        guard bounds.width > 1, bounds.height > 1 else { return }
        _ = synchronizeGeometryAndContent()
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        guard let handler else {
            surfaceView.onFocus = nil
            return
        }
        surfaceView.onFocus = { [weak self] in
            // When the terminal surface gains focus (click, tab, etc.), update the
            // search focus target so window reactivation restores terminal focus.
            if self?.surfaceView.terminalSurface?.searchState != nil {
                self?.searchFocusTarget = .terminal
            }
            handler()
        }
    }

    func beginFindEscapeSuppression() {
        surfaceView.beginFindEscapeSuppression()
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    /// Applies the host-layer terminal fill and optionally clears the shared backdrop behind it.
    func setBackgroundColor(_ color: NSColor, clearsSharedWindowBackdrop: Bool = false) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        synchronizeSharedBackdropCutout(visible: clearsSharedWindowBackdrop)
        layer.backgroundColor = color.cgColor
        layer.isOpaque = color.alphaComponent >= 1.0
        CATransaction.commit()
        // The viewport border strokes the window-chrome separator color, which tracks the
        // terminal background/theme. Repaint it when the background changes (e.g. theme
        // switch) so a connected iOS device's visible-area border stays in sync.
        if !mobileViewportBorderOverlayView.isHidden {
            mobileViewportBorderOverlayView.needsDisplay = true
        }
    }

    /// Keeps the shared-backdrop cutout view present only while a pane-local fill needs it.
    private func synchronizeSharedBackdropCutout(visible: Bool) {
        if visible {
            let cutoutView = sharedBackdropCutoutView ?? makeSharedBackdropCutoutView()
            _ = setFrameIfNeeded(cutoutView, to: bounds)
            return
        }

        sharedBackdropCutoutView?.removeFromSuperview()
        sharedBackdropCutoutView = nil
    }

    /// Creates the Core Image filtered view that subtracts pane-local fills from shared backdrop.
    ///
    /// AppKit requires `layerUsesCoreImageFilters` to be configured before display, so the
    /// cutout view is created lazily only when a pane-local OSC background override needs it.
    private func makeSharedBackdropCutoutView() -> NSView {
        let sharedBackdropCutoutFilter = TerminalSharedBackdropCutoutFilter()
        sharedBackdropCutoutFilter.name = "terminalSharedBackdropCutout"
        let cutoutView = NSView(frame: bounds)
        cutoutView.wantsLayer = true
        cutoutView.layerUsesCoreImageFilters = true
        cutoutView.compositingFilter = sharedBackdropCutoutFilter
        cutoutView.layer?.backgroundColor = NSColor.white.cgColor
        cutoutView.layer?.isOpaque = true
        addSubview(cutoutView, positioned: .below, relativeTo: backgroundView)
        sharedBackdropCutoutView = cutoutView
        return cutoutView
    }

    func setInactiveOverlay(color: NSColor, opacity: CGFloat, visible: Bool) {
        let clampedOpacity = max(0, min(1, opacity))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inactiveOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedOpacity).cgColor
        inactiveOverlayView.isHidden = !(visible && clampedOpacity > 0.0001)
        CATransaction.commit()
    }

    func setNotificationRing(visible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNotificationRing(visible: visible)
            }
            return
        }

        let targetHidden = !visible
        let targetOpacity: Float = visible ? 1 : 0
        guard notificationRingOverlayView.isHidden != targetHidden ||
                notificationRingLayer.opacity != targetOpacity else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingOverlayView.isHidden = targetHidden
        notificationRingLayer.opacity = targetOpacity
        CATransaction.commit()
    }

    private func cancelDeferredSearchOverlayMutation() {
        deferredSearchOverlayMutationWorkItem?.cancel()
        deferredSearchOverlayMutationWorkItem = nil
    }

    private func scheduleDeferredSearchOverlayMutation(
        generation: UInt64,
        _ mutation: @escaping () -> Void
    ) {
        cancelDeferredSearchOverlayMutation()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.searchOverlayMutationGeneration == generation else { return }
            self.deferredSearchOverlayMutationWorkItem = nil
            mutation()
        }
        deferredSearchOverlayMutationWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func cancelImageTransferIndicatorShow() {
        imageTransferIndicatorShowWorkItem?.cancel()
        imageTransferIndicatorShowWorkItem = nil
    }

    private func updateImageTransferIndicatorZOrder(relativeTo overlay: NSView?) {
        guard !imageTransferIndicatorContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: overlay)
            return
        }
        if keyboardCopyModeBadgeContainerView.superview === self,
           !keyboardCopyModeBadgeContainerView.isHidden {
            addSubview(
                imageTransferIndicatorContainerView,
                positioned: .above,
                relativeTo: keyboardCopyModeBadgeContainerView
            )
            return
        }
        addSubview(imageTransferIndicatorContainerView, positioned: .above, relativeTo: nil)
    }

    private func updateKeyboardCopyModeBadgeZOrder(relativeTo overlay: NSView?) {
        guard !keyboardCopyModeBadgeContainerView.isHidden else { return }
        if let overlay, overlay.superview === self {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: overlay)
        } else {
            addSubview(keyboardCopyModeBadgeContainerView, positioned: .above, relativeTo: nil)
        }
        updateImageTransferIndicatorZOrder(relativeTo: overlay)
    }

    @objc private func handleImageTransferCancel() {
        guard let operation = activeImageTransferOperation else { return }
        let onCancel = activeImageTransferCancelHandler
        guard operation.cancel() else { return }
        endImageTransferIndicator(for: operation)
        onCancel?()
    }

    func beginImageTransferIndicator(
        for operation: TerminalImageTransferOperation,
        onCancel: @escaping () -> Void
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.beginImageTransferIndicator(for: operation, onCancel: onCancel)
            }
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = operation
        activeImageTransferCancelHandler = onCancel
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activeImageTransferOperation === operation else { return }
            guard !operation.isCancelled else { return }
            self.imageTransferIndicatorShowWorkItem = nil
            self.imageTransferIndicatorSpinner.startAnimation(nil)
            self.imageTransferIndicatorContainerView.isHidden = false
            self.updateImageTransferIndicatorZOrder(relativeTo: self.searchOverlayHostingView)
        }
        imageTransferIndicatorShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func endImageTransferIndicator(for operation: TerminalImageTransferOperation?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.endImageTransferIndicator(for: operation)
            }
            return
        }

        if let operation,
           activeImageTransferOperation !== operation {
            return
        }

        cancelImageTransferIndicatorShow()
        activeImageTransferOperation = nil
        activeImageTransferCancelHandler = nil
        imageTransferIndicatorSpinner.stopAnimation(nil)
        imageTransferIndicatorContainerView.isHidden = true
    }

    private func makeSearchOverlayRootView(
        terminalSurface: TerminalSurface,
        searchState: TerminalSurface.SearchState
    ) -> SurfaceSearchOverlay {
        SurfaceSearchOverlay(
            tabId: terminalSurface.tabId,
            surfaceId: terminalSurface.id,
            searchState: searchState,
            canApplyFocusRequest: { [weak self] in
                self?.canApplyMountedSearchFieldFocusRequest() ?? false
            },
            onNavigateSearch: { [weak terminalSurface] action in
                _ = terminalSurface?.performBindingAction(action)
            },
            onFieldDidFocus: { [weak self, weak terminalSurface] in
                self?.searchFocusTarget = .searchField
                terminalSurface?.setFocus(false)
            },
            onClose: { [weak self, weak terminalSurface] in
                terminalSurface?.searchState = nil
                self?.moveFocus()
            }
        )
    }

    private func findEditableSearchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = findEditableSearchField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func mountedSearchFieldIfAvailable() -> NSTextField? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return findEditableSearchField(in: overlay)
    }

    private func mountedSearchFieldOwnsResponder(
        _ responder: NSResponder?,
        field: NSTextField? = nil
    ) -> Bool {
        guard let responder else { return false }
        guard let field = field ?? mountedSearchFieldIfAvailable() else { return false }
        return responder === field || field.currentEditor() === responder
    }

    private func resolvedKeyboardFocusOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }

        let mountedSearchField = mountedSearchFieldIfAvailable()
        if mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField
        }

        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            var current = editor.nextResponder
            while let next = current {
                if let view = next as? NSView {
                    return view
                }
                current = next.nextResponder
            }
            return editor.superview ?? editor
        }

        return responder as? NSView
    }

    private func canApplyMountedSearchFieldFocusRequest() -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface,
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: terminalSurface.tabId),
              manager.selectedTabId == terminalSurface.tabId,
              let workspace = manager.tabs.first(where: { $0.id == terminalSurface.tabId }) else {
            return false
        }
        return workspace.focusedPanelId == terminalSurface.id
    }

    private func requestMountedSearchFieldFocus(
        generation: UInt64,
        force: Bool,
        attemptsRemaining: Int = 4
    ) {
        guard searchOverlayMutationGeneration == generation else { return }
        guard force || searchFocusTarget == .searchField else { return }
        guard canApplyMountedSearchFieldFocusRequest() else { return }
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self,
              let window,
              window.isKeyWindow else { return }

        guard let field = findEditableSearchField(in: overlay) else {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.requestMountedSearchFieldFocus(
                    generation: generation,
                    force: force,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        let firstResponder = window.firstResponder
        let alreadyFocused = mountedSearchFieldOwnsResponder(firstResponder, field: field)
        guard !alreadyFocused else { return }

        surfaceView.terminalSurface?.setFocus(false)
        let result = window.makeFirstResponder(field)
#if DEBUG
        cmuxDebugLog(
            "find.mountedFieldFocus surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "result=\(result ? 1 : 0) attemptsRemaining=\(attemptsRemaining) " +
            "firstResponder=\(String(describing: window.firstResponder))"
        )
#endif
        guard !result, attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.requestMountedSearchFieldFocus(
                generation: generation,
                force: force,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    func setSearchOverlay(searchState: TerminalSurface.SearchState?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setSearchOverlay(searchState: searchState)
            }
            return
        }

        searchOverlayMutationGeneration &+= 1
        let mutationGeneration = searchOverlayMutationGeneration

        // Layering contract: keep terminal Cmd+F UI inside this portal-hosted AppKit view.
        // SwiftUI panel-level overlays can fall behind portal-hosted terminal surfaces.
        guard let terminalSurface = surfaceView.terminalSurface,
              let searchState else {
            let hadOverlay = searchOverlayHostingView != nil
            lastSearchOverlayStateID = nil
            searchFocusTarget = .searchField
            guard hadOverlay else {
                cancelDeferredSearchOverlayMutation()
                return
            }
#if DEBUG
            cmuxDebugLog("find.setSearchOverlay REMOVE surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") hadOverlay=\(hadOverlay)")
#endif
            scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self] in
                self?.searchOverlayHostingView?.removeFromSuperview()
                self?.searchOverlayHostingView = nil
            }
            return
        }

        let searchStateID = ObjectIdentifier(searchState)
        if let overlay = searchOverlayHostingView,
           lastSearchOverlayStateID == searchStateID,
           overlay.superview === self {
            cancelDeferredSearchOverlayMutation()
            _ = setFrameIfNeeded(overlay, to: bounds)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        let hadOverlay = searchOverlayHostingView != nil
#if DEBUG
        cmuxDebugLog("find.setSearchOverlay MOUNT surface=\(terminalSurface.id.uuidString.prefix(5)) existingOverlay=\(hadOverlay ? "yes(update)" : "no(create)")")
#endif

        let rootView = makeSearchOverlayRootView(
            terminalSurface: terminalSurface,
            searchState: searchState
        )

        if let overlay = searchOverlayHostingView {
            overlay.rootView = rootView
            lastSearchOverlayStateID = searchStateID
            if overlay.superview !== self {
                scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
                    guard let self, let overlay else { return }
                    overlay.removeFromSuperview()
                    overlay.frame = self.bounds
                    overlay.autoresizingMask = [.width, .height]
                    self.addSubview(overlay)
                    self.updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
                    self.requestMountedSearchFieldFocus(
                        generation: mutationGeneration,
                        force: false
                    )
                }
                return
            }
            cancelDeferredSearchOverlayMutation()
            _ = setFrameIfNeeded(overlay, to: bounds)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        searchFocusTarget = .searchField
        let overlay = TerminalSearchOverlayHostingView(rootView: rootView, surfaceView: surfaceView)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        searchOverlayHostingView = overlay
        lastSearchOverlayStateID = searchStateID
        scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            guard self.searchOverlayHostingView === overlay else { return }
            overlay.removeFromSuperview()
            overlay.frame = self.bounds
            overlay.autoresizingMask = [.width, .height]
            self.addSubview(overlay)
            self.updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            self.requestMountedSearchFieldFocus(
                generation: mutationGeneration,
                force: true
            )
        }
    }

    func syncKeyStateIndicator(text: String?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.syncKeyStateIndicator(text: text)
            }
            return
        }

        if let text, !text.isEmpty {
            keyboardCopyModeBadgeLabel.stringValue = text
            keyboardCopyModeBadgeIconView.setAccessibilityLabel(text)
            let needsReorder = keyboardCopyModeBadgeContainerView.isHidden
                || keyboardCopyModeBadgeContainerView.superview !== self
                || subviews.last !== keyboardCopyModeBadgeContainerView
            keyboardCopyModeBadgeContainerView.isHidden = false
            if needsReorder {
                updateKeyboardCopyModeBadgeZOrder(relativeTo: searchOverlayHostingView)
            }
            return
        }

        keyboardCopyModeBadgeIconView.setAccessibilityLabel(terminalKeyTableIndicatorAccessibilityLabel)
        keyboardCopyModeBadgeContainerView.isHidden = true
    }

    func refreshHostBackgroundAfterGhosttyConfigReload() {
        _ = synchronizeGeometryAndContent()
        surfaceView.applySurfaceBackground()
        surfaceView.applyWindowBackgroundIfActive()
    }

    func reapplySurfaceColorSchemeAfterGhosttyConfigReload(
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        surfaceView.applySurfaceColorScheme(
            force: true,
            preferredColorScheme: preferredColorScheme
        )
    }

    private func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let localFrame = PaneDropRouting.compactOverlayFrame(for: zone, in: size)

        let container = dropZoneOverlayView.superview ?? superview
        guard let container, container !== self else { return localFrame }
        return container.convert(localFrame, from: self)
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDropZoneOverlay(zone: zone)
            }
            return
        }

        if let zone, (bounds.width <= 2 || bounds.height <= 2) {
            pendingDropZone = zone
#if DEBUG
            logDropZoneOverlay(event: "deferZeroBounds", zone: zone, frame: nil)
#endif
            return
        }

        let previousZone = activeDropZone
        activeDropZone = zone
        pendingDropZone = nil

        if let zone {
#if DEBUG
            if window == nil {
                logDropZoneOverlay(event: "showNoWindow", zone: zone, frame: nil)
            }
#endif
            attachDropZoneOverlayIfNeeded()
            let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
            let previousFrame = dropZoneOverlayView.frame
            let isSameFrame = Self.rectApproximatelyEqual(previousFrame, targetFrame)
            let needsFrameUpdate = !isSameFrame
            let zoneChanged = previousZone != zone

            if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            dropZoneOverlayView.layer?.removeAllAnimations()

            if dropZoneOverlayView.isHidden {
                applyDropZoneOverlayFrame(targetFrame)
                dropZoneOverlayView.alphaValue = 0
                dropZoneOverlayView.isHidden = false
#if DEBUG
                recordDropOverlayShowAnimation()
#endif
#if DEBUG
                logDropZoneOverlay(event: "show", zone: zone, frame: targetFrame)
#endif

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dropZoneOverlayView.animator().alphaValue = 1
                } completionHandler: { [weak self] in
#if DEBUG
                    guard let self else { return }
                    guard self.activeDropZone == zone else { return }
                    self.logDropZoneOverlay(event: "showComplete", zone: zone, frame: targetFrame)
#endif
                }
                return
            }

#if DEBUG
            if needsFrameUpdate || zoneChanged {
                logDropZoneOverlay(event: "update", zone: zone, frame: targetFrame)
            }
#endif
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if needsFrameUpdate {
                    dropZoneOverlayView.animator().frame = targetFrame
                }
                if dropZoneOverlayView.alphaValue < 1 {
                    dropZoneOverlayView.animator().alphaValue = 1
                }
            }
        } else {
            guard !dropZoneOverlayView.isHidden else { return }
            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
#if DEBUG
            logDropZoneOverlay(event: "hide", zone: nil, frame: nil)
#endif

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.activeDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
#if DEBUG
                self.logDropZoneOverlay(event: "hideComplete", zone: nil, frame: nil)
#endif
            }
        }
    }

    func setPaneDropContext(_ context: TerminalPaneDropContext?) {
        paneDropTargetView.dropContext = context
        if context == nil {
            paneDropTargetView.draggingExited(nil)
        }
    }

    func paneDropTargetForDrop(at localPoint: NSPoint) -> TerminalPaneDropTargetView? {
        guard bounds.contains(localPoint) else { return nil }
        let pointInTarget = paneDropTargetView.convert(localPoint, from: self)
        guard paneDropTargetView.bounds.contains(pointInTarget) else { return nil }
        guard !paneDropTargetView.shouldDeferToPaneTabBar(at: pointInTarget) else { return nil }
        return paneDropTargetView
    }

#if DEBUG
    private func logDropZoneOverlay(event: String, zone: DropZone?, frame: CGRect?) {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let zoneText = zone.map { String(describing: $0) } ?? "none"
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let overlaySuperviewClass = dropZoneOverlayView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let scrollOriginText = String(
            format: "%.1f,%.1f",
            scrollView.contentView.bounds.origin.x,
            scrollView.contentView.bounds.origin.y
        )
        let surfaceOriginText = String(
            format: "%.1f,%.1f",
            surfaceView.frame.origin.x,
            surfaceView.frame.origin.y
        )
        let frameText: String
        if let frame {
            frameText = String(
                format: "%.1f,%.1f %.1fx%.1f",
                frame.origin.x, frame.origin.y, frame.width, frame.height
            )
        } else {
            frameText = "-"
        }
        let signature =
            "\(event)|\(surface)|\(zoneText)|\(boundsText)|\(frameText)|\(overlaySuperviewClass)|" +
            "\(scrollOriginText)|\(surfaceOriginText)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDropZoneOverlayLogSignature != signature else { return }
        lastDropZoneOverlayLogSignature = signature
        cmuxDebugLog(
            "terminal.dropOverlay event=\(event) surface=\(surface) zone=\(zoneText) " +
            "hidden=\(dropZoneOverlayView.isHidden ? 1 : 0) bounds=\(boundsText) frame=\(frameText) " +
            "overlaySuper=\(overlaySuperviewClass) overlayExternal=\(dropZoneOverlayView.superview === self ? 0 : 1) " +
            "scrollOrigin=\(scrollOriginText) surfaceOrigin=\(surfaceOriginText)"
        )
    }
#endif

    func triggerFlash(style: FlashStyle = .navigation) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastFlashStyle = style
            #if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath(style: style)
            self.updateFlashAppearance(style: style)
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = FocusFlashPattern.values.map { NSNumber(value: $0) }
            animation.keyTimes = FocusFlashPattern.keyTimes.map { NSNumber(value: $0) }
            animation.duration = FocusFlashPattern.duration
            animation.timingFunctions = FocusFlashPattern.curves.map { curve in
                switch curve {
                case .easeIn:
                    return CAMediaTimingFunction(name: .easeIn)
                case .easeOut:
                    return CAMediaTimingFunction(name: .easeOut)
                }
            }
            self.flashLayer.add(animation, forKey: "cmux.flash")
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        let wasVisible = surfaceView.isVisibleInUI
        // Record portal visibility for renderer reclamation. When becoming
        // visible, re-realize the GPU renderer BEFORE marking the surface
        // visible/occluded or kicking any draw, so we never draw into a swap
        // chain that RendererRealizationController released while this surface was
        // offscreen. realizeRenderer() is idempotent (no-op if there is no runtime
        // surface or it is already realized).
        surfaceView.terminalSurface?.setRendererPortalVisible(visible)
        if visible {
            surfaceView.terminalSurface?.realizeRenderer()
        }
        surfaceView.setVisibleInUI(visible)
        isHidden = !visible
        if wasVisible != visible, lastRequestedPortalOcclusionVisible != visible {
            lastRequestedPortalOcclusionVisible = visible
            surfaceView.terminalSurface?.setOcclusion(visible)
        }
#if DEBUG
        if wasVisible != visible {
            let transition = "\(wasVisible ? 1 : 0)->\(visible ? 1 : 0)"
            let suffix = debugVisibilityStateSuffix(transition: transition)
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.visible",
                suffix: suffix
            )
        }
#endif
        if wasVisible != visible {
            NotificationCenter.default.post(
                name: .terminalPortalVisibilityDidChange,
                object: self,
                userInfo: [
                    GhosttyNotificationKey.surfaceId: surfaceView.terminalSurface?.id as Any,
                    GhosttyNotificationKey.tabId: surfaceView.tabId as Any
                ]
            )
        }
        if !visible {
            // If we were focused, yield first responder.
            if let window = uiWindow, let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                window.makeFirstResponder(nil)
            }
        } else if !wasVisible {
            // Workspace/sidebar selection can make an already-sized terminal visible again
            // without a portal frame delta or a focus handoff. Reuse the portal refresh
            // path so the Metal layer is nudged immediately on plain visibility restores.
            refreshSurfaceNow(reason: "setVisibleInUI")
            scheduleAutomaticFirstResponderApply(reason: "setVisibleInUI")
        }
    }

    var debugPortalVisibleInUI: Bool {
        surfaceView.isVisibleInUI
    }

    var debugPortalActive: Bool {
        isActive
    }

    var debugPortalFrameInWindow: CGRect {
        guard uiWindow != nil else { return .zero }
        return convert(bounds, to: nil)
    }

    func setActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
#if DEBUG
        if wasActive != active {
            let transition = "\(wasActive ? 1 : 0)->\(active ? 1 : 0)"
            let suffix = debugVisibilityStateSuffix(transition: transition)
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.active",
                suffix: suffix
            )
        }
#endif
        if active && !wasActive {
            scheduleAutomaticFirstResponderApply(reason: "setActive")
        } else if !active {
            resignOwnedFirstResponderIfNeeded(reason: "setActive(false)")
        }
    }

#if DEBUG
    private func debugLogWorkspaceSwitchTiming(event: String, suffix: String) {
        guard let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() else {
            cmuxDebugLog("\(event) id=none \(suffix)")
            return
        }
        let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
        cmuxDebugLog("\(event) id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) \(suffix)")
    }

    private func debugFirstResponderLabel() -> String {
        guard let window = uiWindow, let firstResponder = window.firstResponder else { return "nil" }
        if let view = firstResponder as? NSView {
            if view === surfaceView {
                return "surfaceView"
            }
            if view.isDescendant(of: surfaceView) {
                return "surfaceDescendant"
            }
            return String(describing: type(of: view))
        }
        return String(describing: type(of: firstResponder))
    }

    private func debugVisibilityStateSuffix(transition: String) -> String {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let hiddenInHierarchy = (isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor) ? 1 : 0
        let inWindow = uiWindow != nil ? 1 : 0
        let hasSuperview = superview != nil ? 1 : 0
        let hostHidden = isHidden ? 1 : 0
        let surfaceHidden = surfaceView.isHidden ? 1 : 0
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let frameText = String(format: "%.1fx%.1f", frame.width, frame.height)
        let responder = debugFirstResponderLabel()
        return
            "surface=\(surface) transition=\(transition) active=\(isActive ? 1 : 0) " +
            "visibleFlag=\(surfaceView.isVisibleInUI ? 1 : 0) hostHidden=\(hostHidden) surfaceHidden=\(surfaceHidden) " +
            "hiddenHierarchy=\(hiddenInHierarchy) inWindow=\(inWindow) hasSuperview=\(hasSuperview) " +
            "bounds=\(boundsText) frame=\(frameText) firstResponder=\(responder)"
    }
#endif

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
#if DEBUG
        let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let searchActive = self.surfaceView.terminalSurface?.searchState != nil
        cmuxDebugLog(
            "find.moveFocus to=\(surfaceShort) " +
            "from=\(previous?.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "searchState=\(searchActive ? "active" : "nil") " +
            "delayMs=\(Int((delay ?? 0) * 1000))"
        )
#endif
        let work = { [weak self] in
            guard let self else { return }
            guard let window = self.uiWindow else { return }
#if DEBUG
            let before = String(describing: window.firstResponder)
#endif
            guard self.canRequestSurfaceFirstResponder(in: window, reason: "moveFocus") else { return }
            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }
            let result = window.makeFirstResponder(self.surfaceView)
#if DEBUG
            cmuxDebugLog(
                "find.moveFocus.apply to=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) before=\(before) after=\(String(describing: window.firstResponder))"
            )
#endif
        }

        if let delay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        } else {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async { work() }
            }
        }
    }

#if DEBUG
    @discardableResult
    func debugSimulateFileDrop(paths: [String], asImageData: Bool = false) -> Bool {
        surfaceView.debugSimulateFileDrop(paths: paths, asImageData: asImageData)
    }

    func debugPendingSurfaceSize() -> CGSize? {
        surfaceView.debugPendingSurfaceSize()
    }

    func debugRegisteredDropTypes() -> [String] {
        surfaceView.debugRegisteredDropTypes()
    }

    func debugInactiveOverlayState() -> (isHidden: Bool, alpha: CGFloat) {
        (
            inactiveOverlayView.isHidden,
            inactiveOverlayView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
        )
    }

    func debugNotificationRingState() -> (isHidden: Bool, opacity: Float) {
        (
            notificationRingOverlayView.isHidden,
            notificationRingLayer.opacity
        )
    }

    struct DebugDropZoneOverlayState {
        let isHidden: Bool
        let frame: CGRect
        let isAttachedToHostedView: Bool
        let isAttachedToParentContainer: Bool
    }

    func debugDropZoneOverlayState() -> DebugDropZoneOverlayState {
        DebugDropZoneOverlayState(
            isHidden: dropZoneOverlayView.isHidden,
            frame: dropZoneOverlayView.frame,
            isAttachedToHostedView: dropZoneOverlayView.superview === self,
            isAttachedToParentContainer: dropZoneOverlayView.superview === superview
        )
    }

    func debugHasSearchOverlay() -> Bool {
        guard let overlay = searchOverlayHostingView else { return false }
        return overlay.superview === self && !overlay.isHidden
    }

    func debugSearchOverlayHostingViewForTesting() -> NSView? {
        guard let overlay = searchOverlayHostingView,
              overlay.superview === self else {
            return nil
        }
        return overlay
    }

    func debugSurfaceHasPendingLeftMouseReleaseForTesting() -> Bool {
        surfaceView.debugHasPendingLeftMouseReleaseForTesting()
    }

    func debugHasKeyboardCopyModeIndicator() -> Bool {
        keyboardCopyModeBadgeContainerView.superview === self && !keyboardCopyModeBadgeContainerView.isHidden
    }

#endif

    fileprivate var hasActiveDropZoneOverlay: Bool {
        activeDropZone != nil || pendingDropZone != nil
    }

    /// Handle file/URL drops, forwarding to the terminal as shell-escaped paths.
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        #if DEBUG
        cmuxDebugLog("terminal.swiftUIDrop surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") urls=\(urls.map(\.lastPathComponent))")
        #endif
        return surfaceView.handleDroppedFileURLs(urls)
    }

    func terminalViewForDrop(at point: NSPoint) -> GhosttyNSView? {
        guard bounds.contains(point), !isHidden else { return nil }
        return surfaceView
    }

#if DEBUG
    /// Sends a synthetic key press/release pair directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike sendText, which bypasses key translation.
    @discardableResult
    func debugSendSyntheticKeyPressAndReleaseForUITest(
        characters: String,
        charactersIgnoringModifiers: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let window = uiWindow else { return false }
        window.makeFirstResponder(surfaceView)

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        guard let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else { return false }

        surfaceView.keyDown(with: keyDown)
        surfaceView.keyUp(with: keyUp)
        return true
    }

    /// Sends a synthetic Ctrl+D key press directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike `sendText`, which bypasses key translation.
    @discardableResult
    func sendSyntheticCtrlDForUITest(modifierFlags: NSEvent.ModifierFlags = [.control]) -> Bool {
        debugSendSyntheticKeyPressAndReleaseForUITest(
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            keyCode: 2,
            modifierFlags: modifierFlags
        )
    }
    #endif

    func ensureFocus(
        for tabId: UUID,
        surfaceId: UUID,
        respectForeignFirstResponder: Bool = true
    ) {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor

        guard isActive else { return }
        guard let window = uiWindow else { return }
        guard surfaceView.isVisibleInUI else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=not_visible"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.notVisible")
            return
        }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.hiddenOrTiny")
            return
        }

        if let terminalSurface = surfaceView.terminalSurface,
           terminalSurface.focusPlacement == .rightSidebarDock {
            guard AppDelegate.shared?.allowsTerminalKeyboardFocus(
                workspaceId: tabId,
                panelId: surfaceId,
                in: window
            ) != false else {
#if DEBUG
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dockCoordinator")
#endif
                return
            }
            if terminalSurface.searchState != nil {
#if DEBUG
                cmuxDebugLog(
                    "focus.ensure.dock.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                    "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                    "firstResponder=\(String(describing: window.firstResponder))"
                )
#endif
                restoreSearchFocus(window: window)
                return
            }
            if let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.alreadyFirstResponder")
                return
            }
            if respectForeignFirstResponder,
               let firstResponder = window.firstResponder,
               shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
                let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
                dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=dock.\(reason)")
#endif
                return
            }
            let result = window.makeFirstResponder(surfaceView)
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.dock.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            if isSurfaceViewFirstResponder() {
                reassertTerminalSurfaceFocus(reason: "ensureFocus.dock.afterMakeFirstResponder")
            }
            return
        }

        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.inactiveTab")
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.missingPane")
            return
        }

        guard tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface,
              tab.bonsplitController.focusedPaneId == paneId else {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.unfocusedPane")
            return
        }

        guard delegate.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: surfaceId, in: window) else {
#if DEBUG
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=coordinatorRightSidebar")
#endif
            return
        }

        // Search focus restoration — only after confirming this is the active tab/pane.
        if surfaceView.terminalSurface?.searchState != nil {
#if DEBUG
            cmuxDebugLog(
                "focus.ensure.search surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            restoreSearchFocus(window: window)
            return
        }

        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.alreadyFirstResponder")
            return
        }

        // Layout and visibility reconciliation can ask the active terminal to
        // reassert focus after a sidebar/text owner has already accepted focus.
        // Respect those explicit AppKit first responders unless the terminal
        // surface already owns focus.
        if respectForeignFirstResponder,
           let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            dlog("focus.ensure.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") reason=\(reason)")
#endif
            return
        }

        if !window.isKeyWindow {
            guard shouldAllowEnsureFocusWindowActivation(
                activeTabManager: delegate.tabManager,
                targetTabManager: tabManager,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow,
                targetWindow: window
            ) else {
                return
            }
            window.makeKeyAndOrderFront(nil)
        }
        let result = window.makeFirstResponder(surfaceView)
#if DEBUG
        cmuxDebugLog(
            "focus.ensure.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
            "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        if !isSurfaceViewFirstResponder() {
            scheduleAutomaticFirstResponderApply(reason: "ensureFocus.afterMakeFirstResponder")
        } else {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.afterMakeFirstResponder")
        }
    }

    func yieldTerminalSurfaceFocusForForeignResponder(reason: String) {
        surfaceView.desiredFocus = false
        pendingSuppressedFirstResponderFocusReapply = false
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        terminalSurface.setFocus(false)
#if DEBUG
        dlog("focus.surface.yield surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func matchesCurrentTerminalFocusTarget(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            return false
        }

        return tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface &&
            tab.bonsplitController.focusedPaneId == paneId
    }

    /// Suppress the surface view's onFocus callback and ghostty_surface_set_focus during
    /// SwiftUI reparenting (programmatic splits). Call clearSuppressReparentFocus() after layout settles.
    func suppressReparentFocus() {
        surfaceView.suppressingReparentFocus = true
    }

    func isSuppressingReparentFocusForLayoutFollowUp() -> Bool {
        surfaceView.suppressingReparentFocus
    }

    func canClearPendingReparentFocusSuppressionAfterLayoutAttempt() -> Bool {
        // After Workspace has flushed a layout follow-up, the protected reparent
        // turn has passed even if AppKit never tried to focus this old view.
        true
    }

    func clearReparentFocusSuppressionForPointerFocus() {
        guard surfaceView.suppressingReparentFocus else { return }
        surfaceView.suppressingReparentFocus = false
#if DEBUG
        cmuxDebugLog("focus.reparent.pointerClear surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
    }

    func clearSuppressReparentFocus() {
        surfaceView.suppressingReparentFocus = false
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let surfaceOwnsFirstResponder = currentTerminalSurfaceOwnsFirstResponder()

        guard surfaceView.desiredFocus || surfaceOwnsFirstResponder else { return }
        guard surfaceView.isVisibleInUI else { return }
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.defer surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            scheduleAutomaticFirstResponderApply(reason: "clearSuppressReparentFocus.hiddenOrTiny")
            return
        }
        if !surfaceOwnsFirstResponder && !isSurfaceViewFirstResponder() {
#if DEBUG
            cmuxDebugLog(
                "focus.reparent.resume.restoreFirstResponder surface=\(surfaceShort) " +
                "firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
            guard requestSurfaceFirstResponder(in: window, reason: "clearSuppressReparentFocus"),
                  isSurfaceViewFirstResponder() else { return }
        }
#if DEBUG
        cmuxDebugLog("focus.reparent.resume surface=\(surfaceShort) firstResponder=\(String(describing: window.firstResponder))")
#endif
        reassertTerminalSurfaceFocus(reason: "clearSuppressReparentFocus", force: true)
    }

    fileprivate func scheduleSuppressedFirstResponderFocusReapply(reason: String) {
        pendingSuppressedFirstResponderFocusReapply = true
        scheduleAutomaticFirstResponderApply(reason: reason)
    }

    fileprivate func cancelSuppressedFirstResponderFocusReapply() {
        pendingSuppressedFirstResponderFocusReapply = false
    }

    fileprivate func scheduleSuppressedFirstResponderFocusReapplyIfReady(reason: String) {
        guard pendingSuppressedFirstResponderFocusReapply else { return }
        guard !pendingAutomaticFirstResponderApply else { return }
        guard isActive, surfaceView.desiredFocus, surfaceView.isVisibleInUI else { return }
        guard currentTerminalSurfaceOwnsFirstResponder() else { return }
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        guard !isHiddenForFocus,
              bounds.width > 1,
              bounds.height > 1,
              surfaceView.bounds.width > 1,
              surfaceView.bounds.height > 1 else {
            return
        }
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard let tabId = surfaceView.tabId,
              let panelId = surfaceView.terminalSurface?.id,
              isRightSidebarDockSurface || matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: panelId),
              AppDelegate.shared?.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: panelId, in: window) != false,
              AppDelegate.shared?.isCommandPaletteEffectivelyVisible(for: window) != true else {
            return
        }
        scheduleAutomaticFirstResponderApply(reason: reason)
    }

    /// Returns true if the terminal's actual Ghostty surface view is (or contains) the window first responder.
    /// This is stricter than checking `hostedView` descendants, since the scroll view can sometimes become
    /// first responder transiently while focus is being applied.
    func isSurfaceViewFirstResponder() -> Bool {
        guard let window = uiWindow, let fr = window.firstResponder as? NSView else { return false }
        return fr === surfaceView || fr.isDescendant(of: surfaceView)
    }

#if DEBUG
    func debugIsSuppressingReparentFocusForTesting() -> Bool {
        surfaceView.suppressingReparentFocus
    }

    func debugHasPendingAutomaticFirstResponderApplyForTesting() -> Bool {
        pendingAutomaticFirstResponderApply
    }
#endif

    private func currentTerminalSurfaceOwnsFirstResponder() -> Bool {
        guard let window = uiWindow, let firstResponder = window.firstResponder as? NSView else { return false }
        if firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView) {
            return true
        }
        guard let terminalSurface = surfaceView.terminalSurface else { return false }
        var current: NSView? = firstResponder
        while let view = current {
            if let ghosttyView = view as? GhosttyNSView,
               ghosttyView.terminalSurface === terminalSurface {
                return true
            }
            current = view.superview
        }
        return false
    }

    private func canRequestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard let terminalSurface = surfaceView.terminalSurface else {
            return true
        }
        let allowed = AppDelegate.shared?.allowsTerminalKeyboardFocus(
            workspaceId: terminalSurface.tabId,
            panelId: terminalSurface.id,
            in: window
        ) ?? true
#if DEBUG
        if !allowed {
            dlog(
                "focus.apply.skip surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "reason=\(reason).coordinatorRightSidebar"
            )
        }
#endif
        return allowed
    }

    @discardableResult
    private func requestSurfaceFirstResponder(in window: NSWindow, reason: String) -> Bool {
        guard canRequestSurfaceFirstResponder(in: window, reason: reason) else {
            return false
        }
        return window.makeFirstResponder(surfaceView)
    }

    private func scheduleAutomaticFirstResponderApply(reason: String) {
        guard !pendingAutomaticFirstResponderApply else { return }
        pendingAutomaticFirstResponderApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutomaticFirstResponderApply = false
#if DEBUG
            let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
            cmuxDebugLog("find.applyFirstResponder.defer surface=\(surfaceShort) reason=\(reason)")
#endif
            self.applyFirstResponderIfNeeded()
        }
    }

    private func prepareTerminalSurfaceFocusReassertion(reason: String, force: Bool) -> Bool {
        let requiresUsableGeometry = pendingSuppressedFirstResponderFocusReapply || force
        guard requiresUsableGeometry else { return true }

        // `force` bypasses TerminalSurface focus coalescing, not AppKit geometry readiness.
        let portalSize = bounds.size
        let surfaceSize = surfaceView.bounds.size
        let hasUsablePortalGeometry = portalSize.width > 1 && portalSize.height > 1
        let hasUsableSurfaceGeometry = surfaceSize.width > 1 && surfaceSize.height > 1
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        guard !isHiddenForFocus, hasUsablePortalGeometry, hasUsableSurfaceGeometry else {
#if DEBUG
            let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
            cmuxDebugLog(
                "focus.surface.reassert.skip surface=\(surfaceShort) reason=\(reason).hidden_or_tiny " +
                "hidden=\(isHiddenForFocus ? 1 : 0) " +
                "force=\(force ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", portalSize.width, portalSize.height)) " +
                "surfaceFrame=\(String(format: "%.1fx%.1f", surfaceSize.width, surfaceSize.height))"
            )
#endif
            pendingSuppressedFirstResponderFocusReapply = true
            scheduleAutomaticFirstResponderApply(reason: "\(reason).hiddenOrTiny")
            return false
        }

        return true
    }

    private func reassertTerminalSurfaceFocus(reason: String, force: Bool = false) {
        guard prepareTerminalSurfaceFocusReassertion(reason: reason, force: force) else { return }
        guard let terminalSurface = surfaceView.terminalSurface else { return }
        if terminalSurface.surface == nil {
            terminalSurface.requestBackgroundSurfaceStartIfNeeded()
        }
#if DEBUG
        cmuxDebugLog("focus.surface.reassert surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.setFocus(true, force: force)
        pendingSuppressedFirstResponderFocusReapply = false
        refreshSurfaceAfterFocusIfNeeded(reason: reason)
    }

    private func refreshSurfaceAfterFocusIfNeeded(reason: String) {
        guard let terminalSurface = surfaceView.terminalSurface,
              isActive,
              let window = uiWindow,
              window.isKeyWindow,
              surfaceView.isVisibleInUI else { return }

        let now = CACurrentMediaTime()
        if now - lastFocusRefreshAt < 0.05 {
            return
        }
        lastFocusRefreshAt = now
#if DEBUG
        cmuxDebugLog("focus.surface.refresh surface=\(terminalSurface.id.uuidString.prefix(5)) reason=\(reason)")
#endif
        terminalSurface.forceRefresh(reason: "focus.surface.\(reason)")
    }

    private func applyFirstResponderIfNeeded() {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let hasUsableSurfaceGeometry: Bool = {
            let size = surfaceView.bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        let requiresSuppressedSurfaceGeometry = pendingSuppressedFirstResponderFocusReapply

        guard isActive else { return }
        guard surfaceView.isVisibleInUI else { return }
        guard !isHiddenForFocus,
              hasUsablePortalGeometry,
              (!requiresSuppressedSurfaceGeometry || hasUsableSurfaceGeometry) else {
#if DEBUG
            cmuxDebugLog(
                "focus.apply.skip surface=\(surfaceShort) " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "surfaceFrame=\(String(format: "%.1fx%.1f", surfaceView.bounds.width, surfaceView.bounds.height))"
            )
#endif
            return
        }
        guard let window = uiWindow, window.isKeyWindow else { return }
        guard let tabId = surfaceView.tabId,
              let panelId = surfaceView.terminalSurface?.id,
              matchesCurrentTerminalFocusTarget(tabId: tabId, surfaceId: panelId) || (pendingSuppressedFirstResponderFocusReapply && isRightSidebarDockSurface && currentTerminalSurfaceOwnsFirstResponder()) else {
#if DEBUG
            cmuxDebugLog("focus.apply.skip surface=\(surfaceShort) reason=stale_target")
#endif
            return
        }
        if AppDelegate.shared?.allowsTerminalKeyboardFocus(workspaceId: tabId, panelId: panelId, in: window) == false {
#if DEBUG
            dlog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=coordinatorRightSidebar")
#endif
            return
        }
        if AppDelegate.shared?.isCommandPaletteEffectivelyVisible(for: window) == true {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=commandPaletteVisible")
#endif
            return
        }
        if surfaceView.terminalSurface?.searchState != nil {
            // Find bar is open. Restore focus based on what the user last intended.
            restoreSearchFocus(window: window)
            return
        }
        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.alreadyFirstResponder")
            return
        }
        // Don't steal focus from a search overlay on another surface in this window.
        if let fr = window.firstResponder, isSearchOverlayOrDescendant(fr) {
#if DEBUG
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=searchOverlayFocused")
#endif
            return
        }
        // Don't steal focus from active non-terminal input owners. The terminal surface uses its
        // own GhosttyNSView for input, so NSText and the feed focus host are always foreign focus
        // owners that should survive deferred terminal visibility applies.
        if let firstResponder = window.firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
           }) {
#if DEBUG
            let reason = firstResponder is NSText ? "textEditorFocused" : "rightSidebarFocused"
            cmuxDebugLog("find.applyFirstResponder SKIP surface=\(surfaceShort) reason=\(reason)")
#endif
            return
        }
#if DEBUG
        cmuxDebugLog("find.applyFirstResponder APPLY surface=\(surfaceShort) prevFirstResponder=\(String(describing: window.firstResponder))")
#endif
        window.makeFirstResponder(surfaceView)
        if isSurfaceViewFirstResponder() {
            reassertTerminalSurfaceFocus(reason: "applyFirstResponder.afterMakeFirstResponder")
        }
    }

    /// Restore focus when window becomes key and the find bar is open.
    /// Respects `searchFocusTarget` so Escape-to-terminal intent is preserved across window switches.
    private func restoreSearchFocus(window: NSWindow) {
        let surfaceShort = String(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
        switch searchFocusTarget {
        case .searchField:
            pendingSuppressedFirstResponderFocusReapply = false
            if let firstResponder = window.firstResponder,
               isCurrentSurfaceSearchFieldResponder(firstResponder) {
                surfaceView.terminalSurface?.setFocus(false)
#if DEBUG
                cmuxDebugLog(
                    "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                    "reason=alreadyFocused firstResponder=\(String(describing: firstResponder))"
                )
#endif
                return
            }
            if let firstResponder = window.firstResponder,
               isSearchOverlayOrDescendant(firstResponder),
               !isCurrentSurfaceSearchResponder(firstResponder) {
                surfaceView.terminalSurface?.setFocus(false)
#if DEBUG
                cmuxDebugLog(
                    "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                    "reason=foreignSearchResponder firstResponder=\(String(describing: firstResponder))"
                )
#endif
                return
            }
            if focusMountedSearchFieldIfAvailable(window: window, surfaceShort: surfaceShort) {
                return
            }
            // Explicitly unfocus the terminal so cursor stops blinking immediately.
            // The notification observer also does this, but it runs async when posted from main.
            surfaceView.terminalSurface?.setFocus(false)
            // Post notification — SearchTextFieldRepresentable's Coordinator
            // observes it and calls makeFirstResponder on the native NSTextField.
            if let terminalSurface = surfaceView.terminalSurface {
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restoreSearchFocus surface=\(surfaceShort) target=searchField " +
                "via=notification firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        case .terminal:
            let result = requestSurfaceFirstResponder(in: window, reason: "restoreSearchFocus.terminal")
            if result, isSurfaceViewFirstResponder() {
                reassertTerminalSurfaceFocus(reason: "restoreSearchFocus.terminal")
            }
#if DEBUG
            cmuxDebugLog(
                "find.restoreSearchFocus surface=\(surfaceShort) target=terminal " +
                "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        }
    }

    @discardableResult
    private func focusMountedSearchFieldIfAvailable(
        window: NSWindow,
        surfaceShort: String
    ) -> Bool {
        guard canApplyMountedSearchFieldFocusRequest() else {
            return false
        }
        guard let field = mountedSearchFieldIfAvailable() else {
            return false
        }

        let firstResponder = window.firstResponder
        let alreadyFocused = mountedSearchFieldOwnsResponder(firstResponder, field: field)

        surfaceView.terminalSurface?.setFocus(false)

#if DEBUG
        if alreadyFocused {
            cmuxDebugLog(
                "find.restoreSearchFocus.skip surface=\(surfaceShort) target=searchField " +
                "reason=mountedFieldAlreadyFocused firstResponder=\(String(describing: firstResponder))"
            )
        }
#endif
        guard !alreadyFocused else { return true }

        let result = window.makeFirstResponder(field)
        let ownsField = mountedSearchFieldOwnsResponder(window.firstResponder, field: field)

#if DEBUG
        cmuxDebugLog(
            "find.restoreSearchFocus surface=\(surfaceShort) target=searchField " +
            "via=mountedField result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        return ownsField
    }

    func capturePanelFocusIntent(in window: NSWindow?) -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil {
            if let firstResponder = window?.firstResponder as? NSView,
               (firstResponder === surfaceView || firstResponder.isDescendant(of: surfaceView)) {
                return .surface
            }
            if let firstResponder = window?.firstResponder,
               isCurrentSurfaceSearchResponder(firstResponder) {
                return .findField
            }
            if searchFocusTarget == .searchField {
                return .findField
            }
        }
        return .surface
    }

    func preferredPanelFocusIntentForActivation() -> TerminalPanelFocusIntent {
        if surfaceView.terminalSurface?.searchState != nil, searchFocusTarget == .searchField {
            return .findField
        }
        return .surface
    }

    func responderMatchesPreferredKeyboardFocus(_ responder: NSResponder) -> Bool {
        switch preferredPanelFocusIntentForActivation() {
        case .surface:
            guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)

        case .findField:
            return isCurrentSurfaceSearchResponder(responder) &&
                isSearchOverlayOrDescendant(responder)
        case .textBoxInput:
            return false
        }
    }

    func preparePanelFocusIntentForActivation(_ intent: TerminalPanelFocusIntent) {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
        case .findField:
            guard surfaceView.terminalSurface?.searchState != nil else { return }
            searchFocusTarget = .searchField
        case .textBoxInput:
            searchFocusTarget = .terminal
        }
#if DEBUG
        let targetLabel: String = {
            switch intent {
            case .surface:
                return "terminal"
            case .findField:
                return "searchField"
            case .textBoxInput:
                return "textBoxInput"
            }
        }()
        cmuxDebugLog(
            "find.preparePanelFocusIntent surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(targetLabel)"
        )
#endif
    }

    @discardableResult
    func restorePanelFocusIntent(_ intent: TerminalPanelFocusIntent) -> Bool {
        switch intent {
        case .surface:
            searchFocusTarget = .terminal
            setActive(true)
            applyFirstResponderIfNeeded()
            return true
        case .findField:
            guard let terminalSurface = surfaceView.terminalSurface,
                  terminalSurface.searchState != nil else {
                return false
            }
            searchFocusTarget = .searchField
            setActive(true)
            if let window {
                restoreSearchFocus(window: window)
            } else {
                terminalSurface.setFocus(false)
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
#if DEBUG
            cmuxDebugLog(
                "find.restorePanelFocusIntent surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "target=searchField firstResponder=\(String(describing: window?.firstResponder))"
            )
#endif
            return true
        case .textBoxInput:
            return false
        }
    }

    func ownedPanelFocusIntent(for responder: NSResponder) -> TerminalPanelFocusIntent? {
        if isCurrentSurfaceSearchResponder(responder) {
            return .findField
        }

        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return nil }
        if view === surfaceView || view.isDescendant(of: surfaceView) {
            return .surface
        }
        return nil
    }

    @discardableResult
    func yieldPanelFocusIntent(_ intent: TerminalPanelFocusIntent, in window: NSWindow) -> Bool {
        guard intent != .textBoxInput else {
            return false
        }
        guard let firstResponder = window.firstResponder,
              ownedPanelFocusIntent(for: firstResponder) == intent else {
            return false
        }
        if intent == .findField { _ = cmuxRememberFindSelection(in: searchOverlayHostingView) }
        surfaceView.terminalSurface?.setFocus(false)
        pendingSuppressedFirstResponderFocusReapply = false
        resignOwnedFirstResponderIfNeeded(reason: "yieldPanelFocusIntent")
#if DEBUG
        cmuxDebugLog(
            "focus.handoff.yield surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "target=\(intent == .findField ? "searchField" : "terminal")"
        )
#endif
        return true
    }

    private func resignOwnedFirstResponderIfNeeded(reason: String) {
        guard let window,
              let firstResponder = window.firstResponder else { return }

        let ownsSurfaceResponder: Bool = {
            guard let view = firstResponder as? NSView else { return false }
            return view === surfaceView || view.isDescendant(of: surfaceView)
        }()

        guard ownsSurfaceResponder || isCurrentSurfaceSearchResponder(firstResponder) else { return }

        pendingSuppressedFirstResponderFocusReapply = false
#if DEBUG
        cmuxDebugLog(
            "focus.surface.resign surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "reason=\(reason) firstResponder=\(String(describing: firstResponder))"
        )
#endif
        window.makeFirstResponder(nil)
    }

    /// Check if a responder is inside a search overlay hosting view.
    /// Handles the AppKit field-editor case: when an NSTextField is being edited,
    /// window.firstResponder is the shared NSTextView field editor, not the text field.
    private func isSearchOverlayOrDescendant(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        var current: NSView? = view
        while let v = current {
            if v is NSHostingView<SurfaceSearchOverlay> { return true }
            let typeName = String(describing: type(of: v))
            if typeName.contains("BrowserSearchOverlay") { return true }
            current = v.superview
        }
        return false
    }

    private func isCurrentSurfaceSearchResponder(_ responder: NSResponder) -> Bool {
        guard let view = resolvedKeyboardFocusOwnerView(for: responder) else { return false }
        return view.isDescendant(of: self)
    }

    private func isCurrentSurfaceSearchFieldResponder(_ responder: NSResponder) -> Bool {
        if let mountedSearchField = mountedSearchFieldIfAvailable(),
           mountedSearchFieldOwnsResponder(responder, field: mountedSearchField) {
            return mountedSearchField.isDescendant(of: self) &&
                isSearchOverlayOrDescendant(mountedSearchField)
        }

        guard let textField = responder as? NSTextField else { return false }
        return textField.isDescendant(of: self) && isSearchOverlayOrDescendant(textField)
    }

#if DEBUG
    struct DebugRenderStats {
        let drawCount: Int
        let lastDrawTime: CFTimeInterval
        let metalDrawableCount: Int
        let metalLastDrawableTime: CFTimeInterval
        let presentCount: Int
        let lastPresentTime: CFTimeInterval
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func debugRenderStats() -> DebugRenderStats {
        let layerClass = surfaceView.layer.map { String(describing: type(of: $0)) } ?? "nil"
        let (metalCount, metalLast) = (surfaceView.layer as? GhosttyMetalLayer)?.debugStats() ?? (0, 0)
        let (drawCount, lastDraw): (Int, CFTimeInterval) = surfaceView.terminalSurface.map { terminalSurface in
            Self.drawStats(for: terminalSurface.id)
        } ?? (0, 0)
        let (presentCount, lastPresent, contentsKey): (Int, CFTimeInterval, String) = surfaceView.terminalSurface.map { terminalSurface in
            let stats = Self.updatePresentStats(surfaceId: terminalSurface.id, layer: surfaceView.layer)
            return (stats.count, stats.last, stats.key)
        } ?? (0, 0, Self.contentsKey(for: surfaceView.layer))
        let inWindow = (window != nil)
        let windowIsKey = window?.isKeyWindow ?? false
        let windowOcclusionVisible = (window?.occlusionState.contains(.visible) ?? false) || (window?.isKeyWindow ?? false)
        let appIsActive = NSApp.isActive
        let fr = window?.firstResponder as? NSView
        let isFirstResponder = fr == surfaceView || (fr?.isDescendant(of: surfaceView) ?? false)
        return DebugRenderStats(
            drawCount: drawCount,
            lastDrawTime: lastDraw,
            metalDrawableCount: metalCount,
            metalLastDrawableTime: metalLast,
            presentCount: presentCount,
            lastPresentTime: lastPresent,
            layerClass: layerClass,
            layerContentsKey: contentsKey,
            inWindow: inWindow,
            windowIsKey: windowIsKey,
            windowOcclusionVisible: windowOcclusionVisible,
            appIsActive: appIsActive,
            isActive: isActive,
            desiredFocus: surfaceView.desiredFocus,
            isFirstResponder: isFirstResponder
        )
    }
#endif

#if DEBUG
    struct DebugFrameSample {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double
        let fingerprint: UInt64
        let iosurfaceWidthPx: Int
        let iosurfaceHeightPx: Int
        let expectedWidthPx: Int
        let expectedHeightPx: Int
        let layerClass: String
        let layerContentsGravity: String
        let layerContentsKey: String

        var isProbablyBlank: Bool {
            (lumaStdDev < 3.5 && modeFraction > 0.985) ||
            (uniqueQuantized <= 6 && modeFraction > 0.95)
        }
    }

    /// Create a CGImage from the terminal's IOSurface-backed layer contents.
    ///
    /// This avoids Screen Recording permissions (unlike CGWindowListCreateImage) and is therefore
    /// suitable for debug socket tests running in headless/VM contexts.
    func debugCopyIOSurfaceCGImage() -> CGImage? {
        guard let modelLayer = surfaceView.layer else { return nil }
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return nil }

        let cf = contents as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return nil }
        let surfaceRef = (contents as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        let bytesPerRow = Int(IOSurfaceGetBytesPerRow(surfaceRef))
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let size = bytesPerRow * height
        let data = Data(bytes: base, count: size)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Sample the IOSurface backing the terminal layer (if any) to detect a transient blank frame
    /// without using screenshots/screen recording permissions.
    func debugSampleIOSurface(normalizedCrop: CGRect) -> DebugFrameSample? {
        guard let modelLayer = surfaceView.layer else { return nil }
        // Prefer the presentation layer to better match what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        let layerClass = String(describing: type(of: layer))
        let layerContentsGravity = layer.contentsGravity.rawValue
        let contentsKey = Self.contentsKey(for: layer)
        let presentationScale = max(1.0, layer.contentsScale)
        let expectedWidthPx = Int((layer.bounds.width * presentationScale).rounded(.toNearestOrAwayFromZero))
        let expectedHeightPx = Int((layer.bounds.height * presentationScale).rounded(.toNearestOrAwayFromZero))

        // Ghostty uses a CoreAnimation layer whose `contents` is an IOSurface-backed object.
        // The concrete layer class is often `IOSurfaceLayer` (private), so avoid referencing it directly.
        guard let anySurface = layer.contents else {
            // Treat "no contents" as a blank frame: this is the visual regression we're guarding.
            return DebugFrameSample(
                sampleCount: 0,
                uniqueQuantized: 0,
                lumaStdDev: 0,
                modeFraction: 1,
                fingerprint: 0,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        // IOSurfaceLayer.contents is usually an IOSurface, but during mitigation we may
        // temporarily replace contents with a CGImage snapshot to avoid blank flashes.
        // Treat non-IOSurface contents as "non-blank" and avoid unsafe casts.
        let cf = anySurface as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else {
            var fnv: UInt64 = 1469598103934665603
            for b in contentsKey.utf8 {
                fnv ^= UInt64(b)
                fnv &*= 1099511628211
            }
            return DebugFrameSample(
                sampleCount: 1,
                uniqueQuantized: 1,
                lumaStdDev: 999,
                modeFraction: 0,
                fingerprint: fnv,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        let surfaceRef = (anySurface as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surfaceRef)
        if bytesPerRow <= 0 { return nil }

        // Assume 4 bytes/pixel BGRA (common for IOSurfaceLayer contents).
        let bytesPerPixel = 4
        let step = 6

        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        var count = 0
        var fnv: UInt64 = 1469598103934665603

        for y in stride(from: y0, to: y1, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: x0, to: x1, by: step) {
                let p = row.advanced(by: x * bytesPerPixel)
                let b = Double(p.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(p.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(p.load(fromByteOffset: 2, as: UInt8.self))
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(r) >> 4)
                let gq = UInt16(UInt8(g) >> 4)
                let bq = UInt16(UInt8(b) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                let lq = UInt8(max(0, min(63, Int(luma / 4.0))))
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return DebugFrameSample(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv,
            iosurfaceWidthPx: width,
            iosurfaceHeightPx: height,
            expectedWidthPx: expectedWidthPx,
            expectedHeightPx: expectedHeightPx,
            layerClass: layerClass,
            layerContentsGravity: layerContentsGravity,
            layerContentsKey: contentsKey
        )
    }
#endif

    func cancelFocusRequest() {
        // Intentionally no-op (no retry loops).
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        guard !pointApproximatelyEqual(surfaceView.frame.origin, visibleRect.origin) else { return }
#if DEBUG
        logDragGeometryChange(event: "surfaceOrigin", old: surfaceView.frame.origin, new: visibleRect.origin)
#endif
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Match upstream Ghostty behavior: use content area width (excluding non-content
    /// regions such as scrollbar space) when telling libghostty the terminal size.
    @discardableResult
    private func synchronizeCoreSurface() -> Bool {
        let width = max(0, surfaceView.frame.width)
        let height = surfaceView.frame.height
        guard width > 0, height > 0 else { return false }
        return surfaceView.pushTargetSurfaceSize(CGSize(width: width, height: height))
    }

    private func updateNotificationRingPath() {
        updateOverlayRingPath(
            layer: notificationRingLayer,
            bounds: notificationRingOverlayView.bounds,
            inset: NotificationRingMetrics.inset,
            radius: NotificationRingMetrics.cornerRadius
        )
    }

    private func updateFlashPath(style: FlashStyle) {
        let inset: CGFloat
        let radius: CGFloat
        switch style {
        case .navigation, .notification:
            inset = NotificationRingMetrics.inset
            radius = NotificationRingMetrics.cornerRadius
        }
        updateOverlayRingPath(
            layer: flashLayer,
            bounds: flashOverlayView.bounds,
            inset: inset,
            radius: radius
        )
    }

    private func updateFlashAppearance(style: FlashStyle) {
        let presentation = Self.flashPresentation(for: style)
        let strokeColor = presentation.accent.strokeColor
        flashLayer.strokeColor = strokeColor.cgColor
        flashLayer.shadowColor = strokeColor.cgColor
        flashLayer.shadowOpacity = Float(presentation.glowOpacity)
        flashLayer.shadowRadius = presentation.glowRadius
    }

    private func updateOverlayRingPath(
        layer: CAShapeLayer,
        bounds: CGRect,
        inset: CGFloat,
        radius: CGFloat
    ) {
        layer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            layer.path = nil
            return
        }
        let rect = PanelOverlayRingMetrics.pathRect(in: bounds)
        layer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        var didChangeGeometry = false
        let targetDocumentHeight = documentHeight()
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)

                // Check if we're currently at the bottom (with threshold for float drift)
                let currentOrigin = scrollView.contentView.bounds.origin
                let documentHeight = documentView.frame.height
                let viewportHeight = scrollView.contentView.bounds.height
                let distanceFromBottom = documentHeight - currentOrigin.y - viewportHeight
                let isAtBottom = distanceFromBottom <= Self.scrollToBottomThreshold

                // Update userScrolledAwayFromBottom based on current position
                if isAtBottom {
                    userScrolledAwayFromBottom = false
                }

                // Passive bottom packets should not override an explicit scrollback review,
                // but the first scrollbar packet caused by the user's own wheel input should
                // still move the viewport to the requested scrollback position.
                let shouldAutoScroll = !userScrolledAwayFromBottom || allowExplicitScrollbarSync

                if shouldAutoScroll && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    scrollView.contentView.scroll(to: targetOrigin)
                    didChangeGeometry = true
                }
                lastSentRow = Int(scrollbar.offset)
            }
        }

        allowExplicitScrollbarSync = false

        if didChangeGeometry {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
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

        // Track if user has scrolled away from bottom to review scrollback
        if scrollOffset > Self.scrollToBottomThreshold {
            userScrolledAwayFromBottom = true
        } else if scrollOffset <= 0 {
            userScrolledAwayFromBottom = false
        }

        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        let wasVisible = scrollView.hasVerticalScroller
        if pendingExplicitWheelScroll {
            userScrolledAwayFromBottom = scrollbar.offset + scrollbar.len < scrollbar.total
            allowExplicitScrollbarSync = true
            pendingExplicitWheelScroll = false
        }
        surfaceView.scrollbar = scrollbar
        let isVisible = shouldShowTerminalScrollBar()
        if wasVisible != isVisible {
            _ = synchronizeGeometryAndContent()
            return
        }
        synchronizeScrollView()
    }

    @discardableResult
    private func synchronizeScrollbarAppearance() -> Bool {
        let shouldShowScrollBar = shouldShowTerminalScrollBar()
        let didChange =
            scrollView.hasVerticalScroller != shouldShowScrollBar ||
            scrollView.autohidesScrollers != false ||
            scrollView.scrollerStyle != .overlay
        scrollView.hasVerticalScroller = shouldShowScrollBar
        // Mirror upstream Ghostty: keep overlay scrollers even when the
        // system preference is legacy so terminal content never sits beneath a
        // permanently reserved scrollbar gutter.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        updateTrackingAreas()
        return didChange
    }

    private func handlePreferredScrollerStyleChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePreferredScrollerStyleChange()
            }
            return
        }

        synchronizeScrollbarAppearance()

        // Retile just the scroll view so contentSize reflects the current
        // scroller preference without perturbing hosted terminal geometry.
        scrollView.tile()
        _ = synchronizeCoreSurface()
    }

    private func handleTerminalScrollBarPreferenceChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleTerminalScrollBarPreferenceChange()
            }
            return
        }

        _ = synchronizeGeometryAndContent()
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

    private func terminalScrollBarAllowedBySettings() -> Bool {
        guard GhosttyApp.shared.scrollbarVisibility() != .never else { return false }
        guard TerminalScrollBarSettings.isVisible() else { return false }
        return true
    }

    private func surfaceHasScrollback() -> Bool? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        // Embedded Ghostty exposes alternate-screen TUIs to the wrapper as a
        // viewport with no additional scrollback (`total <= len`). Treat that
        // as the signal to suppress the overlay scrollbar so full-screen apps
        // like nvim/htop do not pin it on top of the rightmost cell column.
        return scrollbar.total > scrollbar.len
    }

    private func shouldShowTerminalScrollBar() -> Bool {
        guard terminalScrollBarAllowedBySettings() else { return false }
        guard let hasScrollback = surfaceHasScrollback() else {
            // Ghostty reports scrollback asynchronously. Until the first packet
            // arrives, keep the scroller visible so restored/reattached
            // surfaces with existing scrollback do not appear broken.
            return true
        }
        return hasScrollback
    }

}

// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    /// Deliver committed text using typed-input semantics so shells and editors
    /// keep their normal interactive behaviors (autosuggestions, Return
    /// execution, etc.). Programmatic callers can preserve literal ESC bytes so
    /// automation payloads remain byte-for-byte stable.
    fileprivate func sendTextToSurface(_ chars: String, preserveLiteralEscape: Bool) {
        guard let surface = surface else { return }
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
#endif
#if DEBUG
        TerminalChildExitProbe().write(
            [
                "probeInsertTextCharsHex": chars.unicodeScalarHexList,
                "probeInsertTextSurfaceId": terminalSurface?.id.uuidString ?? "",
            ],
            increments: ["probeInsertTextCount": 1]
        )
#endif

        var bufferedText = ""
        var previousWasCR = false

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = 0
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            bufferedText.withCString { ptr in
                keyEvent.text = ptr
                _ = sendGhosttyKey(surface, keyEvent)
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func sendControlKey(_ keycode: UInt32) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = keycode
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            keyEvent.text = nil
            _ = sendGhosttyKey(surface, keyEvent)
        }

        for scalar in chars.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    sendControlKey(0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D:
                flushBufferedText()
                sendControlKey(0x24) // kVK_Return
                previousWasCR = true
            case 0x09:
                flushBufferedText()
                sendControlKey(0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B:
                if preserveLiteralEscape {
                    bufferedText.unicodeScalars.append(scalar)
                } else {
                    flushBufferedText()
                    sendControlKey(0x35) // kVK_Escape
                }
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushBufferedText()
#if DEBUG
        CmuxTypingTiming.logDuration(
            path: "terminal.sendTextToSurface",
            startedAt: typingTimingStart,
            extra: "textBytes=\(chars.utf8.count)"
        )
#endif
    }

    /// External accessibility/dictation tools should commit plain text, but
    /// some inject a leading escape sequence first. Strip those bytes on the
    /// committed-text path so they can't leak into the PTY as literals.
    static func sanitizeExternalCommittedText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return text }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = consumeLeadingEscapeSequence(in: bytes, from: index)
                continue
            }

            if byte == 0xC2 {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x9B {
                    // U+009B (C1 CSI) is encoded as the UTF-8 byte pair C2 9B.
                    index = consumeLeadingCSISequence(in: bytes, from: next + 1)
                    continue
                }
            }

            break
        }

        if index == 0 {
            return text
        }

        guard index < bytes.count else { return "" }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    private static func consumeLeadingEscapeSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        let next = start + 1
        guard next < bytes.count else { return bytes.count }

        switch bytes[next] {
        case 0x5B:
            // CSI: ESC [ ... final
            return consumeLeadingCSISequence(in: bytes, from: next + 1)
        case 0x4F:
            // SS3: ESC O final
            return min(bytes.count, next + 2)
        case 0x50, 0x5D, 0x5E, 0x5F:
            // DCS/OSC/PM/APC: consume until BEL/ST or EOF.
            return consumeLeadingEscapedStringSequence(in: bytes, from: next + 1)
        default:
            // Single-character escape.
            return min(bytes.count, next + 1)
        }
    }

    private static func consumeLeadingCSISequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x20...0x3F).contains(byte) {
                index += 1
                continue
            }

            if (0x40...0x7E).contains(byte) {
                return index + 1
            }

            break
        }

        return index
    }

    private static func consumeLeadingEscapedStringSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }

            if byte == 0x1B {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x5C {
                    return next + 1
                }
                return index
            }

            if byte < 0x20 || byte == 0x7F {
                return index + 1
            }

            index += 1
        }

        return bytes.count
    }

    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        if markedText.length > 0 {
#if DEBUG
            assert(markedSelectedRange.location != NSNotFound, "markedSelectedRange must be valid")
#endif
            return markedSelectedRange
        }
        return readSelectionSnapshot()?.range ?? NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.setMarkedText",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length)"
            )
        }
#endif
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            return
        }
        markedSelectedRange = normalizedMarkedSelectionRange(selectedRange, markedLength: markedText.length)

        // If we're not in a keyDown event, sync preedit immediately.
        // This can happen due to external events like changing keyboard layouts
        // while composing.
        if keyTextAccumulator == nil {
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    func unmarkText() {
#if DEBUG
        let hadMarkedText = markedText.length > 0
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.unmarkText",
                startedAt: typingTimingStart,
                extra: "hadMarkedText=\(hadMarkedText ? 1 : 0)"
            )
        }
#endif
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty.
    /// This tells Ghostty about IME composition text so it can render the
    /// preedit overlay (e.g. for Korean, Japanese, Chinese input).
    private func syncPreedit(clearIfNeeded: Bool = true) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.syncPreedit",
                startedAt: typingTimingStart,
                extra: "markedLength=\(markedText.length) clearIfNeeded=\(clearIfNeeded ? 1 : 0)"
            )
        }
#endif
        guard let surface = surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if markedText.length > 0 {
            guard let substringRange = clampedMarkedTextRange(range, markedLength: markedText.length) else { return nil }
            actualRange?.pointee = substringRange
            return markedText.attributedSubstring(from: substringRange)
        }

        guard range.length > 0,
              let snapshot = readSelectionSnapshot() else { return nil }
        actualRange?.pointee = snapshot.range
        return NSAttributedString(string: snapshot.string)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return selectedRange().location
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Use Ghostty's IME point API for accurate cursor position if available.
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
#if DEBUG
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let override = imePointOverrideForTesting {
            x = override.x
            y = override.y
            w = override.width
            h = override.height
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#else
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }
#endif

        if range.length == 0, w > 0 {
            // Dictation expects a caret rect for insertion points rather than a box.
            w = 0
        }

        // Ghostty coordinates are top-left origin; AppKit expects bottom-left.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: w,
            height: max(h, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func attributedString() -> NSAttributedString {
        if markedText.length > 0 {
            return NSAttributedString(attributedString: markedText)
        }
        if let snapshot = readSelectionSnapshot(), !snapshot.string.isEmpty {
            return NSAttributedString(string: snapshot.string)
        }
        return NSAttributedString(string: "")
    }

    func windowLevel() -> Int {
        Int(window?.level.rawValue ?? NSWindow.Level.normal.rawValue)
    }

    @available(macOS 14.0, *)
    var unionRectInVisibleSelectedRange: NSRect {
        firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    @available(macOS 14.0, *)
    var documentVisibleRect: NSRect {
        visibleDocumentRectInScreenCoordinates()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "terminal.insertText",
                startedAt: typingTimingStart,
                event: NSApp.currentEvent,
                extra: "replacementLocation=\(replacementRange.location) replacementLength=\(replacementRange.length)"
            )
        }
#endif
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

        if keyTextAccumulator != nil,
           shouldBufferBopomofoInsertedPreedit(chars) {
            insertBopomofoPreeditText(chars, replacementRange: replacementRange)
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // Some IME/input-method paths call insertText with an empty payload to
        // flush state. There is no terminal text to send in that case.
        guard !chars.isEmpty else { return }

        if shouldSuppressDeferredNumpadIMECommit(chars) {
            return
        }

#if DEBUG
        if NSApp.currentEvent == nil {
            cmuxDebugLog("ime.insertText.noEvent len=\(chars.count)")
        }
#endif

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        let isExternalCommittedText = externalCommittedTextDepth > 0
        let sanitizedChars = if isExternalCommittedText {
            // Only sanitize explicit external committed-text paths used by
            // AX/dictation integrations. Programmatic NSTextInputClient callers
            // may intentionally start with ESC/CSI bytes.
            Self.sanitizeExternalCommittedText(chars)
        } else {
            chars
        }

#if DEBUG
        if sanitizedChars != chars {
            cmuxDebugLog(
                "ime.insertText.sanitized originalBytes=\(chars.utf8.count) " +
                "sanitizedBytes=\(sanitizedChars.utf8.count)"
            )
        }
#endif

        guard !sanitizedChars.isEmpty else { return }

        // Otherwise send directly to the terminal
        recordDirectAgentHibernationTerminalInput()
        sendTextToSurface(
            sanitizedChars,
            preserveLiteralEscape: !isExternalCommittedText
        )
    }

    private func insertBopomofoPreeditText(_ chars: String, replacementRange: NSRange) {
        let effectiveRange = effectiveBopomofoPreeditReplacementRange(replacementRange)
        if let range = Range(effectiveRange, in: markedText.string) {
            let insertionLocation = effectiveRange.location + (chars as NSString).length
            let next = markedText.string.replacingCharacters(in: range, with: chars)
            markedText = NSMutableAttributedString(string: next)
            markedSelectedRange = normalizedMarkedSelectionRange(
                NSRange(location: insertionLocation, length: 0),
                markedLength: markedText.length
            )
            return
        }

        markedText.append(NSAttributedString(string: chars))
        markedSelectedRange = normalizedMarkedSelectionRange(
            NSRange(location: markedText.length, length: 0),
            markedLength: markedText.length
        )
    }

    private func effectiveBopomofoPreeditReplacementRange(_ replacementRange: NSRange) -> NSRange {
        guard replacementRange.location == NSNotFound else { return replacementRange }
        guard markedText.length > 0 else { return NSRange(location: 0, length: 0) }
        return normalizedMarkedSelectionRange(markedSelectedRange, markedLength: markedText.length)
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    @Environment(\.paneDropZone) var paneDropZone

    let terminalSurface: TerminalSurface
    let paneId: PaneID
    var isActive: Bool = true
    var isVisibleInUI: Bool = true
    var portalZPriority: Int = 0
    var showsInactiveOverlay: Bool = false
    var showsUnreadNotificationRing: Bool = false
    var inactiveOverlayColor: NSColor = .clear
    var inactiveOverlayOpacity: Double = 0
    var searchState: TerminalSurface.SearchState? = nil
    var reattachToken: UInt64 = 0
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    private final class HostContainerView: NSView {
        private static var nextInstanceSerial: UInt64 = 0

        var onDidMoveToWindow: (() -> Void)?
        var onGeometryChanged: (() -> Void)?
        let instanceSerial: UInt64
        private(set) var geometryRevision: UInt64 = 0
        private var lastReportedGeometryState: GeometryState?

        override init(frame frameRect: NSRect) {
            Self.nextInstanceSerial &+= 1
            instanceSerial = Self.nextInstanceSerial
            super.init(frame: frameRect)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) not implemented")
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        private struct GeometryState: Equatable {
            let frame: CGRect
            let bounds: CGRect
            let windowNumber: Int?
            let superviewID: ObjectIdentifier?
        }

        private func currentGeometryState() -> GeometryState {
            GeometryState(
                frame: frame,
                bounds: bounds,
                windowNumber: window?.windowNumber,
                superviewID: superview.map(ObjectIdentifier.init)
            )
        }

        private func notifyGeometryChangedIfNeeded() {
            let state = currentGeometryState()
            guard state != lastReportedGeometryState else { return }
            lastReportedGeometryState = state
            geometryRevision &+= 1
            onGeometryChanged?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onDidMoveToWindow?()
            notifyGeometryChangedIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            notifyGeometryChangedIfNeeded()
        }

        override func layout() {
            super.layout()
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            notifyGeometryChangedIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            notifyGeometryChangedIfNeeded()
        }
    }

    final class Coordinator {
        var attachGeneration: Int = 0
        // Track the latest desired state so attach retries can re-apply focus after re-parenting.
        var desiredIsActive: Bool = true
        var desiredIsVisibleInUI: Bool = true
        var desiredShowsUnreadNotificationRing: Bool = false
        var desiredPortalZPriority: Int = 0
        var lastBoundHostId: ObjectIdentifier?
        var lastPaneDropZone: DropZone?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
        weak var hostedView: GhosttySurfaceScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func shouldApplyImmediateHostedStateUpdate(
        desiredVisibleInUI: Bool, hostedViewHasSuperview: Bool, isBoundToCurrentHost: Bool
    ) -> Bool {
        if !desiredVisibleInUI { return true }
        // If this update originates from a stale/replaced host while the hosted view is
        // already attached elsewhere, do not mutate visibility/active state here.
        if isBoundToCurrentHost { return true }
        return !hostedViewHasSuperview
    }

    enum HostCallbackPortalGeometrySynchronizationAction<Window> {
        case skip
        case synchronizeWithoutLayoutFlush(Window)
    }

    static func hostCallbackPortalGeometrySynchronizationAction<Window>(
        window: Window?
    ) -> HostCallbackPortalGeometrySynchronizationAction<Window> {
        // HostContainerView callbacks can fire while SwiftUI/AppKit is already
        // rendering or laying out the representable. Keep the immediate path,
        // but forbid ancestor layout flushes from this callback.
        guard let window else { return .skip }
        return .synchronizeWithoutLayoutFlush(window)
    }

    private static func synchronizePortalGeometry(
        for host: HostContainerView,
        coordinator: Coordinator
    ) {
        let geometryRevision = host.geometryRevision
        guard coordinator.lastSynchronizedHostGeometryRevision != geometryRevision else { return }
        coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
        // Avoid forcing ancestor AppKit layout while SwiftUI is still inside
        // the current update/layout turn. Reconcile the portal against the
        // already-current host geometry so terminal content tracks resize
        // without reopening the CATransaction display-link reentry path.
        guard case .synchronizeWithoutLayoutFlush = hostCallbackPortalGeometrySynchronizationAction(
            window: host.window
        ) else { return }
        TerminalWindowPortalRegistry.synchronizeForAnchor(host, syncLayout: false)
    }

    func makeNSView(context: Context) -> NSView {
        let container = HostContainerView(frame: .zero)
        container.wantsLayer = false
        // The actual terminal surface lives in the AppKit portal layer above SwiftUI.
        // This empty placeholder should not be walked by the accessibility subsystem.
        container.setAccessibilityRole(.none)
        container.setAccessibilityElement(false)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hostedView = terminalSurface.hostedView
        let coordinator = context.coordinator
        let previousDesiredIsActive = coordinator.desiredIsActive
        let previousDesiredIsVisibleInUI = coordinator.desiredIsVisibleInUI
        let previousDesiredPortalZPriority = coordinator.desiredPortalZPriority
        let desiredStateChanged =
            previousDesiredIsActive != isActive ||
            previousDesiredIsVisibleInUI != isVisibleInUI ||
            previousDesiredPortalZPriority != portalZPriority
        coordinator.desiredIsActive = isActive
        coordinator.desiredIsVisibleInUI = isVisibleInUI
        coordinator.desiredShowsUnreadNotificationRing = showsUnreadNotificationRing
        coordinator.desiredPortalZPriority = portalZPriority
        coordinator.hostedView = hostedView
#if DEBUG
        if desiredStateChanged {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.update id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(terminalSurface.id.uuidString.prefix(5)) visible=\(isVisibleInUI ? 1 : 0) " +
                    "active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.update id=none surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0) z=\(portalZPriority) " +
                    "hostWindow=\(nsView.window != nil ? 1 : 0) hostedWindow=\(hostedView.window != nil ? 1 : 0) " +
                    "hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                )
            }
        }
#endif

        let hostContainer = nsView as? HostContainerView
        let hostOwnsPortalNow = hostContainer.map { host in
            terminalSurface.claimPortalHost(
                hostId: ObjectIdentifier(host),
                paneId: paneId,
                instanceSerial: host.instanceSerial,
                inWindow: host.window != nil,
                bounds: host.bounds,
                reason: "update"
            )
        } ?? true

        // Keep the surface lifecycle and handlers updated even if we defer re-parenting.
        hostedView.attachSurface(terminalSurface)
        hostedView.setFocusHandler { onFocus?(terminalSurface.id) }
        hostedView.setTriggerFlashHandler(onTriggerFlash)
        if hostOwnsPortalNow {
            hostedView.setPaneDropContext(TerminalPaneDropContext(
                workspaceId: terminalSurface.tabId,
                panelId: terminalSurface.id,
                paneId: paneId
            ))
            hostedView.setInactiveOverlay(
                color: inactiveOverlayColor,
                opacity: CGFloat(inactiveOverlayOpacity),
                visible: showsInactiveOverlay
            )
            hostedView.setNotificationRing(visible: showsUnreadNotificationRing)
            hostedView.setSearchOverlay(searchState: searchState)
            hostedView.syncKeyStateIndicator(text: terminalSurface.currentKeyStateIndicatorText)
        }
        let portalExpectedSurfaceId = terminalSurface.id
        let portalExpectedGeneration = terminalSurface.portalBindingGeneration()
        func portalBindingStillLive() -> Bool {
            terminalSurface.canAcceptPortalBinding(
                expectedSurfaceId: portalExpectedSurfaceId,
                expectedGeneration: portalExpectedGeneration
            )
        }
        let forwardedDropZone = isVisibleInUI ? paneDropZone : nil
#if DEBUG
        if coordinator.lastPaneDropZone != paneDropZone {
            let oldZone = coordinator.lastPaneDropZone.map { String(describing: $0) } ?? "none"
            let newZone = paneDropZone.map { String(describing: $0) } ?? "none"
            cmuxDebugLog(
                "terminal.paneDropZone surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) " +
                "active=\(isActive ? 1 : 0) visible=\(isVisibleInUI ? 1 : 0) " +
                "inWindow=\(hostedView.window != nil ? 1 : 0)"
            )
            coordinator.lastPaneDropZone = paneDropZone
        }
        if paneDropZone != nil, !isVisibleInUI {
            cmuxDebugLog(
                "terminal.paneDropZone.suppress surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                "requested=\(String(describing: paneDropZone!)) visible=0 active=\(isActive ? 1 : 0)"
            )
        }
#endif
        if hostOwnsPortalNow {
            hostedView.setDropZoneOverlay(zone: forwardedDropZone)
        }

        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "didMoveToWindow"
                ) else { return }
                guard host.window != nil else { return }
                guard portalBindingStillLive() else { return }
                TerminalWindowPortalRegistry.bind(
                    hostedView: hostedView,
                    to: host,
                    visibleInUI: coordinator.desiredIsVisibleInUI,
                    zPriority: coordinator.desiredPortalZPriority,
                    expectedSurfaceId: portalExpectedSurfaceId,
                    expectedGeneration: portalExpectedGeneration,
                    deferLayoutSynchronization: true
                )
                coordinator.lastBoundHostId = ObjectIdentifier(host)
                coordinator.lastSynchronizedHostGeometryRevision = host.geometryRevision
                hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                hostedView.setActive(coordinator.desiredIsActive)
                hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
            }
            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard terminalSurface.claimPortalHost(
                    hostId: ObjectIdentifier(host),
                    paneId: paneId,
                    instanceSerial: host.instanceSerial,
                    inWindow: host.window != nil,
                    bounds: host.bounds,
                    reason: "geometryChanged"
                ) else { return }
                guard portalBindingStillLive() else { return }
                let hostId = ObjectIdentifier(host)
                if host.window != nil,
                   (coordinator.lastBoundHostId != hostId ||
                    !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)) {
#if DEBUG
                    cmuxDebugLog(
                        "ws.hostState.rebindOnGeometry surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                    )
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration,
                        deferLayoutSynchronization: true
                    )
                    coordinator.lastBoundHostId = hostId
                    hostedView.setVisibleInUI(coordinator.desiredIsVisibleInUI)
                    hostedView.setActive(coordinator.desiredIsActive)
                    hostedView.setNotificationRing(visible: coordinator.desiredShowsUnreadNotificationRing)
                }
                Self.synchronizePortalGeometry(
                    for: host,
                    coordinator: coordinator
                )
            }

            if host.window != nil, hostOwnsPortalNow {
                let portalBindingLive = portalBindingStillLive()
                let hostId = ObjectIdentifier(host)
                let geometryRevision = host.geometryRevision
                let portalEntryMissing = !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
                // Notification rings are hosted inside GhosttySurfaceScrollView and update in place.
                // A ring-only state change must not resynchronize the window portal while SwiftUI is
                // invalidating notification UI, or the terminal can be hidden until the next tab switch.
                let shouldBindNow =
                    coordinator.lastBoundHostId != hostId ||
                    hostedView.superview == nil ||
                    portalEntryMissing ||
                    previousDesiredIsVisibleInUI != isVisibleInUI ||
                    previousDesiredPortalZPriority != portalZPriority
                if portalBindingLive && shouldBindNow {
#if DEBUG
                    if portalEntryMissing {
                        cmuxDebugLog(
                            "ws.hostState.rebindOnUpdate surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                            "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                            "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                        )
                    }
#endif
                    TerminalWindowPortalRegistry.bind(
                        hostedView: hostedView,
                        to: host,
                        visibleInUI: coordinator.desiredIsVisibleInUI,
                        zPriority: coordinator.desiredPortalZPriority,
                        expectedSurfaceId: portalExpectedSurfaceId,
                        expectedGeneration: portalExpectedGeneration,
                        deferLayoutSynchronization: true
                    )
                    coordinator.lastBoundHostId = hostId
                    coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
                } else if portalBindingLive && coordinator.lastSynchronizedHostGeometryRevision != geometryRevision {
                    Self.synchronizePortalGeometry(
                        for: host,
                        coordinator: coordinator
                    )
                }
            } else if hostOwnsPortalNow, portalBindingStillLive() {
                // Bind is deferred until host moves into a window. Update the
                // existing portal entry's visibleInUI now so that any portal sync
                // that runs before the deferred bind completes won't hide the view.
#if DEBUG
                if desiredStateChanged {
                    cmuxDebugLog(
                        "ws.hostState.deferBind surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                        "reason=hostNoWindow visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority) " +
                        "hostedWindow=\(hostedView.window != nil ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0)"
                    )
                }
#endif
                TerminalWindowPortalRegistry.updateEntryVisibility(
                    for: hostedView,
                    visibleInUI: coordinator.desiredIsVisibleInUI
                )
            }
        }

        let hostWindowAttached = hostContainer?.window != nil
        let isBoundToCurrentHost = hostContainer.map { host in
            TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host)
        } ?? true
        let shouldApplyImmediateHostedState = hostOwnsPortalNow && Self.shouldApplyImmediateHostedStateUpdate(
            desiredVisibleInUI: isVisibleInUI,
            hostedViewHasSuperview: hostedView.superview != nil,
            isBoundToCurrentHost: isBoundToCurrentHost
        )

        if portalBindingStillLive() && shouldApplyImmediateHostedState {
            hostedView.setVisibleInUI(isVisibleInUI)
            hostedView.setActive(isActive)
        } else {
            // Preserve portal entry visibility while a stale host is still receiving SwiftUI updates.
            // The currently bound host remains authoritative for immediate visible/active state.
#if DEBUG
            if desiredStateChanged {
                cmuxDebugLog(
                    "ws.hostState.deferApply surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                    "reason=\(hostOwnsPortalNow ? "staleHostBinding" : "hostOwnershipRejected") " +
                    "hostWindow=\(hostWindowAttached ? 1 : 0) " +
                    "boundToCurrent=\(isBoundToCurrentHost ? 1 : 0) hostedSuperview=\(hostedView.superview != nil ? 1 : 0) " +
                    "visible=\(isVisibleInUI ? 1 : 0) active=\(isActive ? 1 : 0)"
                )
            }
#endif
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil
        let hostedView = coordinator.hostedView
#if DEBUG
        if let hostedView {
            if let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) " +
                    "surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            } else {
                cmuxDebugLog(
                    "ws.swiftui.dismantle id=none surface=\(hostedView.debugSurfaceId?.uuidString.prefix(5) ?? "nil") " +
                    "inWindow=\(hostedView.window != nil ? 1 : 0)"
                )
            }
        }
#endif

        if let host = nsView as? HostContainerView {
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
            hostedView?.prepareOwnedPortalHostForTransientReattach(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        // SwiftUI can transiently dismantle/rebuild NSViewRepresentable instances during split
        // tree updates. Do not drop the portal lease or force visible/active false here; that
        // causes avoidable blackouts when the same hosted view is rebound moments later.
        hostedView?.setFocusHandler(nil)
        hostedView?.setTriggerFlashHandler(nil)
        hostedView?.setDropZoneOverlay(zone: nil)
        coordinator.hostedView = nil

        nsView.subviews.forEach { $0.removeFromSuperview() }
    }
}
