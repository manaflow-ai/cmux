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
                defaultValue: "No user Ghostty settings, so cmux applies its managed default colors."
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
/// links validate hosts and resolve bare domains through the same browser
/// rules the embedded browser uses.
struct TerminalBrowserHostNormalizer: BrowserHostNormalizing {
    func normalizedHost(_ rawHost: String) -> String? {
        BrowserInsecureHTTPSettings.normalizeHost(rawHost)
    }

    func navigableWebURL(_ input: String) -> URL? {
        resolveBrowserNavigableURL(input)
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

    /// Concrete hot-path snapshot for consumers that apply their own ranking.
    func allTerminalSurfacesUnordered() -> [TerminalSurface] {
        allSurfacesUnordered().compactMap { $0 as? TerminalSurface }
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
    fileprivate let desktopNotificationIngress = GhosttyDesktopNotificationIngress()

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
    static let terminalPasteboard = TerminalPasteboardService(
        previousContentsCapture: { request in
            do {
                return try await TerminalPastePreparationWorkerClient
                    .snapshottingWithCurrentBinary()
                    .captureSnapshot(request)
            } catch {
                return nil
            }
        }
    )

    /// The process-wide bounded native-surface free queue (was the
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
        viewProvider: {
            let pasteboardService = GhosttyApp.terminalPasteboard
            let preparationService = TerminalImageTransferPreparationService(
                operation: { request in
                    let client = TerminalPastePreparationWorkerClient
                        .reexecingCurrentBinary(
                            pasteboardService: pasteboardService
                    )
                    return try await client.prepare(request)
                },
                cleanup: { result in
                    result.cleanupTransferredTemporaryFiles(
                        using: pasteboardService
                    )
                }
            )
            return TerminalSurfaceViewFactory(
                imageTransferPreparation: preparationService
            )
        }(),
        spawnPolicy: TerminalSurfaceSpawnPolicyBridge(),
        byteTee: TerminalOutputByteTeeBridge(),
        rendererRealization: RendererRealizationController.shared,
        hibernationRecorder: TerminalAgentHibernationRecorder(),
        runtimeTeardown: GhosttyApp.terminalSurfaceRuntimeTeardown,
        restoreSpawnScheduler: GhosttyApp.terminalSurfaceRestoreSpawnScheduler,
        runtimeFilesystem: .live(),
        sessionPortBase: GhosttyApp.terminalSessionPortBase,
        sessionPortRangeSize: GhosttyApp.terminalSessionPortRangeSize,
        scrollbackReplayEnvironmentKey:
            SessionScrollbackReplayStore.environmentKey,
        globalFontMagnificationPercent: {
            GhosttyApp.shared.appliedGlobalFontMagnificationPercent
        }
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
    private var nativeReloadActionSuppressionDepth = 0
    typealias ConfigurationReloadCompletion =
        @MainActor () -> Void
    private let configurationReloadCoordinator =
        TerminalConfigurationReloadCoordinator()
    private let terminalFontConfigurationReloadReconciler =
        TerminalFontConfigurationReloadReconciler()
    private(set) var appliedGlobalFontMagnificationPercent =
        GlobalFontMagnification.storedPercent
    private(set) var terminalFontConfigurationGeneration: UInt64 = 0
    private var pendingAppearanceSynchronization: PendingAppearanceSynchronization?
    private(set) var usesHostLayerBackground = false
    private(set) var userGhosttyShellIntegrationMode: String = "detect"
    private(set) var hasUserGhosttyCommand = false
    private(set) var resolvedUserShell: String?

    func storedShortcut(
        forBindingAction action: String
    ) -> StoredShortcut? {
        guard let config else { return nil }
        let trigger = action.withCString { pointer in
            ghostty_config_trigger(
                config,
                pointer,
                UInt(action.utf8.count)
            )
        }
        let tag: GhosttyTriggerInput.Tag
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            tag = .physical(
                GhosttyTriggerPhysicalKey(
                    ghosttyPhysicalKey:
                        trigger.key.physical
                )
            )
        case GHOSTTY_TRIGGER_UNICODE:
            tag = .unicode(
                UnicodeScalar(trigger.key.unicode)
            )
        case GHOSTTY_TRIGGER_CATCH_ALL:
            tag = .catchAll
        default:
            return nil
        }

        let input = GhosttyTriggerInput(
            tag: tag,
            modifiers: GhosttyModifierMask(
                rawValue: trigger.mods.rawValue
            )
        )
        guard let shortcut =
                GhosttyTriggerShortcut(decoding: input) else {
            return nil
        }
        return StoredShortcut(
            key: shortcut.key,
            command: shortcut.command,
            shift: shortcut.shift,
            option: shortcut.option,
            control: shortcut.control
        )
    }

    @MainActor
    func deferRuntimeSurfaceCreationForConfigurationReload(
        _ action: @escaping @MainActor () -> Void
    ) -> Bool {
        terminalFontConfigurationReloadReconciler
            .enqueuePostConfigurationWork(
                .init(attempt: {
                    action()
                    return true
                })
            )
    }

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
    @MainActor private lazy var terminalBellService = TerminalBellService()
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
    @MainActor private lazy var scrollEndTimer = MainActorCoalescingDeadlineTimer(owner: self) { owner in
        owner.endScrollSession()
    }

    @MainActor
    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            scrollEndTimer.cancel()
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            scrollEndTimer.cancel()
            isScrolling = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrolling = true
            scrollEndTimer.schedule(after: .milliseconds(150))
        }
    }

    @MainActor
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
                sentryCaptureWarning(
                    "Scroll lag detected",
                    category: "scroll_lag",
                    data: [
                        "samples": samples,
                        "avg_ms": String(format: "%.2f", avgLag),
                        "max_ms": String(format: "%.2f", maxLag),
                        "threshold_ms": threshold
                    ]
                )
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

        resolvedUserShell = TerminalShellResolver.resolveCurrentUserShell()
        if let resolvedUserShell {
            setenv("SHELL", resolvedUserShell, 1)
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
            guard let content,
                  let callbackContext = GhosttyApp.callbackContext(from: userdata) else { return }
            // Libghostty invokes this synchronously from the main-actor
            // completion above. Stay inline so confirmation is registered
            // before that completion's defer can release buffered input.
            MainActor.assumeIsolated {
                guard let surfaceIdentity = TerminalClipboardRequestSurfaceIdentity(
                    terminalSurface: callbackContext.terminalSurface
                ) else { return }
                callbackContext.confirmClipboardRead(
                    String(cString: content),
                    stateAddress: UInt(bitPattern: state),
                    surfaceIdentity: surfaceIdentity
                )
            }
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            let decoder = TerminalClipboardRepresentationDecoder()

            var fallback: String?
            var representations: [TerminalClipboardRepresentation] = []
            representations.reserveCapacity(Int(len))
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                if let mimePtr = item.mime {
                    let mimeType = String(cString: mimePtr)
                    guard let representation = decoder.decode(
                        mimeType: mimeType,
                        data: dataPtr
                    ) else { continue }
                    representations.append(representation)
                } else if fallback == nil {
                    fallback = decoder.decode(
                        mimeType: nil,
                        data: dataPtr
                    )?.string
                }
            }

            if let fallback,
               !representations.contains(where: {
                   $0.mimeType.lowercased().hasPrefix("text/plain")
               }) {
                representations.append(.init(mimeType: "text/plain", string: fallback))
            }
            GhosttyApp.terminalPasteboard.writeRepresentations(representations, to: location)
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
            hasUserGhosttyCommand = false

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
            _ = MainActor.assumeIsolated {
                self?.reloadConfiguration(source: "settings.terminal.copyOnSelect")
            }
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: TerminalAdaptiveDefaultThemeSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _ = MainActor.assumeIsolated {
                self?.reloadConfiguration(
                    source: "settings.terminal.adaptiveDefaultTheme"
                )
            }
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

    /// Loads the user's resolved Ghostty config. When enabled, cmux's managed
    /// default appearance is applied only if the config contains no directives;
    /// otherwise Ghostty's own resolved colors are preserved.
    private func loadRealUserGhosttyConfig(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        themeColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        let appearanceSummary = Self.userAppearanceConfigSummary()
        let adaptiveDefaultThemeEnabled =
            TerminalAdaptiveDefaultThemeSettings().isEnabled
        let shouldApplyManagedDefaultAppearance =
            adaptiveDefaultThemeEnabled
            && appearanceSummary.shouldApplyDefaultAppearance
        if shouldApplyManagedDefaultAppearance {
            loadCmuxDefaultAppearanceConfig(config, preferredColorScheme: preferredColorScheme)
        }
        ghostty_config_load_default_files(config)
        loadLegacyGhosttyConfigIfNeeded(config)
        loadCmuxAppSupportGhosttyConfigIfNeeded(config)
        ghostty_config_load_recursive_files(config)
        loadConditionalThemeOverrideIfNeeded(config, preferredColorScheme: themeColorScheme)
        // Ghostty's own default-file load also reads the native legacy app-support
        // `config` that cmux's scan-path policy treats as stale when `config.ghostty`
        // is non-empty. For an otherwise untouched config, re-assert the managed
        // default so that skipped legacy-file colors cannot override it.
        if shouldApplyManagedDefaultAppearance {
            loadCmuxDefaultAppearanceConfig(config, preferredColorScheme: preferredColorScheme)
        }
        hasUserGhosttyCommand = GhosttyConfig.loadForCmux(
            preferredColorScheme: preferredColorScheme,
            useCache: false
        ).command != nil
    }

    func loadDefaultConfigFilesWithLegacyFallback(
        _ config: ghostty_config_t,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference = GhosttyConfig.currentColorSchemePreference(),
        conditionalThemeColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) -> Bool {
        hasUserGhosttyCommand = false
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
        // cmux owns these split, close, and workspace font-size shortcuts through
        // KeyboardShortcutSettings.
        // Remove Ghostty's default fallbacks so remapped or cleared shortcuts
        // can reach the focused terminal instead of running actions outside the
        // remappable shortcut layer.
        loadInlineGhosttyConfig(
            """
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            keybind = super+ctrl+==unbind
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
        configPaths: [String]? = nil,
        adaptiveDefaultThemeEnabled: Bool =
            TerminalAdaptiveDefaultThemeSettings().isEnabled
    ) -> Bool {
        configDiscovery.shouldApplyManagedDefaultAppearance(
            configPaths: configPaths,
            adaptiveDefaultThemeEnabled: adaptiveDefaultThemeEnabled
        )
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
        case deferred(colorScheme: GhosttyConfig.ColorSchemePreference)
        case reload(
            colorScheme: GhosttyConfig.ColorSchemePreference,
            runtimeColorScheme: ghostty_color_scheme_e
        )

        var shouldReloadConfiguration: Bool {
            switch self {
            case .unchanged, .deferred:
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
        currentColorScheme: GhosttyConfig.ColorSchemePreference,
        isConfigurationReloadInProgress: Bool = false
    ) -> AppearanceSynchronizationPlan {
        if isConfigurationReloadInProgress {
            return .deferred(colorScheme: currentColorScheme)
        }

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

    @MainActor
    @discardableResult
    func reloadConfiguration(
        soft: Bool = false,
        source: String = "unspecified",
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil,
        completion: ConfigurationReloadCompletion? = nil
    ) -> Bool {
        let request = TerminalPendingConfigurationReload(
            soft: soft,
            source: source,
            reloadSettingsFromFile: reloadSettingsFromFile,
            preferredColorScheme: preferredColorScheme,
            completions: completion.map { [$0] } ?? []
        )
        return enqueueConfigurationReload(request)
    }

    @MainActor
    private func enqueueConfigurationReload(
        _ request: TerminalPendingConfigurationReload
    ) -> Bool {
        let result =
            configurationReloadCoordinator.enqueue(request)
        if result.needsFontWorkBarrier {
            schedulePendingConfigurationReload()
        }
        return result.retainedAllCompletions
    }

    @MainActor
    private func schedulePendingConfigurationReload() {
        guard configurationReloadCoordinator
                .isWaitingForFontWork else {
            return
        }
        guard let arbiter =
                AppDelegate.shared?.workspaceTerminalFontSizeArbiter else {
            performPendingConfigurationReload(completion: {})
            return
        }
        arbiter.performWhenFontSizeWorkIsIdle {
            [weak self, weak arbiter] in
            guard let self else { return }
            guard let arbiter else {
                self.performPendingConfigurationReload(completion: {})
                return
            }
            let releaseBarrier =
                arbiter.extendCurrentFontSizeWorkIdleBarrier()
            self.performPendingConfigurationReload(
                completion: releaseBarrier
            )
        }
    }

    @MainActor
    private func performPendingConfigurationReload(
        completion: @escaping @MainActor () -> Void
    ) {
        guard let request =
                configurationReloadCoordinator
                    .takePendingRequest() else {
            completion()
            return
        }
        performConfigurationReload(request) { [weak self] in
            guard let self else {
                request.completions.forEach { $0() }
                completion()
                return
            }
            let shouldScheduleNext =
                self.configurationReloadCoordinator
                    .finishReload()
            self.drainPendingAppearanceSynchronization()
            request.completions.forEach { $0() }
            if shouldScheduleNext {
                self.schedulePendingConfigurationReload()
            }
            completion()
        }
    }

    @MainActor
    private func performConfigurationReload(
        _ request: TerminalPendingConfigurationReload,
        completion: @escaping @MainActor () -> Void
    ) {
        let requestedSoft = request.soft
        let source = request.source
        let reloadSettingsFromFile = request.reloadSettingsFromFile
        let preferredColorScheme = request.preferredColorScheme
        let fontTransaction =
            TerminalFontConfigurationReloadTransaction.prepare(
                appliedMagnificationPercent:
                    appliedGlobalFontMagnificationPercent,
                reloadSettings: {
                    if reloadSettingsFromFile {
                        KeyboardShortcutSettings
                            .settingsFileStore.reload()
                    }
                    AppDelegate.shared?
                        .reloadCmuxConfigStores(source: source)
                },
                storedMagnificationPercent: {
                    GlobalFontMagnification.storedPercent
                }
            )
        let reloadMagnificationPercent =
            fontTransaction.targetMagnificationPercent
        // Reusing the old Ghostty config cannot apply an imported scale.
        // Promote this transaction. A reload requested by the magnification
        // observer is queued behind this transaction by the coordinator.
        let soft =
            requestedSoft
            && !fontTransaction.magnificationDidChange
        let reloadColorScheme = preferredColorScheme ?? appearanceBackedColorSchemePreference()
        guard let app else {
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=no_app")
            completion()
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
        let previousRuntimeColorScheme =
            appliedGhosttyRuntimeColorScheme
        let previousEffectiveColorScheme =
            effectiveTerminalColorSchemePreference
        synchronizeGhosttyRuntimeColorScheme(loadColorScheme, source: "reloadConfiguration:\(source):load")
        logThemeAction("reload begin source=\(source) soft=\(soft)")
        resetDefaultBackgroundUpdateScope(source: "reloadConfiguration(source=\(source))")
        if soft, let config {
            let effectiveReloadColorScheme = effectiveTerminalColorSchemePreference
            synchronizeGhosttyRuntimeColorScheme(effectiveReloadColorScheme, source: "reloadConfiguration:\(source):resolved")
            suppressGhosttyReloadActions {
                ghostty_app_update_config(app, config)
            }
            lastAppearanceColorScheme = reloadColorScheme
            GhosttyConfig.invalidateLoadCache()
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            refreshSurfacesAfterConfigurationReload(
                source: source,
                preferredColorScheme: effectiveReloadColorScheme
            )
            logThemeAction("reload end source=\(source) soft=\(soft) mode=soft")
            completion()
            return
        }

        guard let newConfig = ghostty_config_new() else {
            if let previousRuntimeColorScheme {
                synchronizeGhosttyRuntimeColorScheme(
                    previousRuntimeColorScheme,
                    colorScheme:
                        previousEffectiveColorScheme,
                    source:
                        "reloadConfiguration:\(source):restore"
                )
            }
            logThemeAction("reload skipped source=\(source) soft=\(soft) reason=config_alloc_failed")
            completion()
            return
        }
        let renderingModeChanged = loadDefaultConfigFilesWithLegacyFallback(
            newConfig,
            preferredColorScheme: reloadColorScheme
        )
        let stagedBaselineAppearance =
            defaultBackgroundValues(from: newConfig)
        GhosttyConfig.invalidateLoadCache()
        let stagedResolvedAppearance =
            resolvedDefaultBackgroundValues(
                preferredColorScheme: reloadColorScheme,
                baselineConfig: newConfig
            )
        let effectiveReloadColorScheme =
            Self.terminalRuntimeColorSchemePreference(
                forBackgroundColor:
                    stagedResolvedAppearance
                        .backgroundColor
            )
        // Ghostty consults its runtime scheme while loading conditional
        // themes. Restore the applied scheme before incremental capture so
        // neither the renderer nor surrounding UI exposes the staged theme.
        if let previousRuntimeColorScheme {
            synchronizeGhosttyRuntimeColorScheme(
                previousRuntimeColorScheme,
                colorScheme:
                    previousEffectiveColorScheme,
                source:
                    "reloadConfiguration:\(source):staged"
            )
        }
        let terminalFontConfiguration =
            terminalFontConfigurationSnapshot(
                config: newConfig,
                magnificationPercent:
                    reloadMagnificationPercent
            )
        AppDelegate.shared?
            .workspaceTerminalFontSizeArbiter
            .setCurrentFontSizeWorkIdleBarrierProjectionConfiguration(
                terminalFontConfiguration
            )
        let registryTraversal =
            Self.terminalSurfaceRegistry
                .makeIncrementalTraversal()
        configurationReloadCoordinator
            .beginReconciliation()
        terminalFontConfigurationReloadReconciler
            .reconcileIncrementally(
                captureNextWork: {
                    guard let visit =
                            registryTraversal.nextVisit() else {
                        return nil
                    }
                    guard let surface =
                            visit.surface as? TerminalSurface else {
                        return .init(attempt: { true })
                    }
                    let reloadState =
                        surface
                            .captureFontSizeConfigurationReloadState(
                                magnificationPercent:
                                    fontTransaction
                                        .previousMagnificationPercent,
                                targetConfiguredRuntimePoints:
                                    terminalFontConfiguration
                                        .configuredRuntimePoints,
                                targetMagnificationPercent:
                                    terminalFontConfiguration
                                        .magnificationPercent
                            )
                    return .init(
                        attempt: { [weak surface] in
                            guard let surface else {
                                return true
                            }
                            guard Self.terminalSurfaceRegistry
                                    .isRegistered(surface) else {
                                surface
                                    .abandonFontSizeConfigurationReloadReconciliation(
                                        from: reloadState,
                                        magnificationPercent:
                                            terminalFontConfiguration
                                                .magnificationPercent
                                    )
                                return true
                            }
                            let outcome =
                                surface
                                    .reconcileFontSizeAfterConfigurationReload(
                                        from: reloadState,
                                        configuredRuntimePoints:
                                            terminalFontConfiguration
                                                .configuredRuntimePoints,
                                        magnificationPercent:
                                            terminalFontConfiguration
                                                .magnificationPercent
                                    )
                            if outcome == .failed {
                                Self.initializationLogger.error(
                                    "Terminal font reconciliation attempt failed after config reload surface=\(surface.id.uuidString, privacy: .public)"
                                )
                            }
                            return outcome.didSucceed
                        },
                        abandon: { [weak surface] in
                            guard let surface else { return }
                            surface
                                .abandonFontSizeConfigurationReloadReconciliation(
                                    from: reloadState,
                                    magnificationPercent:
                                        terminalFontConfiguration
                                            .magnificationPercent
                                )
                            Self.initializationLogger.error(
                                "Terminal font reconciliation rolled back after retry exhaustion surface=\(surface.id.uuidString, privacy: .public)"
                            )
                        }
                    )
                },
                applyConfiguration: {
                    self.suppressGhosttyReloadActions {
                        ghostty_app_update_config(
                            app,
                            newConfig
                        )
                    }
                    self.appliedGlobalFontMagnificationPercent =
                        reloadMagnificationPercent
                    self.terminalFontConfigurationGeneration &+= 1
                    if let oldConfig = self.config {
                        ghostty_config_free(oldConfig)
                    }
                    self.config = newConfig
                    let appearanceSource =
                        "reloadConfiguration(source=\(source))"
                    self.applyDefaultBackground(
                        stagedBaselineAppearance,
                        source: appearanceSource,
                        scope: .unscoped,
                        forceNotify:
                            renderingModeChanged
                    )
                    self.applyDefaultBackground(
                        stagedResolvedAppearance,
                        source:
                            "\(appearanceSource).resolvedGhosttyConfig",
                        scope: .unscoped,
                        forceNotify:
                            renderingModeChanged
                    )
                    self.synchronizeGhosttyRuntimeColorScheme(
                        effectiveReloadColorScheme,
                        source:
                            "reloadConfiguration:\(source):resolved"
                    )
                    Task { @MainActor [weak self] in
                        self?.applyBackgroundToKeyWindow()
                    }
                }
            ) { [weak self] in
                guard let self else {
                    completion()
                    return
                }
                self.lastAppearanceColorScheme = reloadColorScheme
                NotificationCenter.default.post(
                    name: .ghosttyConfigDidReload,
                    object: nil
                )
                self.refreshSurfacesAfterConfigurationReload(
                    source: source,
                    preferredColorScheme:
                        effectiveReloadColorScheme
                )
                self.logThemeAction(
                    "reload end source=\(source) soft=\(soft) mode=full"
                )
                completion()
            }
    }

    @MainActor
    private func suppressGhosttyReloadActions<Result>(
        _ body: () -> Result
    ) -> Result {
        nativeReloadActionSuppressionDepth += 1
        defer {
            nativeReloadActionSuppressionDepth -= 1
        }
        return body()
    }

    @MainActor
    private func refreshSurfacesAfterConfigurationReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        AppDelegate.shared?.refreshTerminalSurfacesAfterGhosttyConfigReload(
            source: source,
            preferredColorScheme: preferredColorScheme
        )
    }

    @MainActor
    var isConfigurationReloadActive: Bool {
        configurationReloadCoordinator.isReloadActive
    }

    @MainActor
    func terminalFontConfigurationSnapshot()
        -> WorkspaceTerminalFontConfigurationSnapshot {
        terminalFontConfigurationSnapshot(
            config: config,
            magnificationPercent:
                appliedGlobalFontMagnificationPercent
        )
    }

    @MainActor
    private func terminalFontConfigurationSnapshot(
        config: ghostty_config_t?,
        magnificationPercent: Int
    ) -> WorkspaceTerminalFontConfigurationSnapshot {
        var configuredRuntimePoints: Float32 = 0
        let key = "font-size"
        if let config,
           ghostty_config_get(
                config,
                &configuredRuntimePoints,
                key,
                UInt(key.lengthOfBytes(using: .utf8))
           ),
           configuredRuntimePoints.isFinite,
           configuredRuntimePoints > 0 {
            return WorkspaceTerminalFontConfigurationSnapshot(
                configuredRuntimePoints: configuredRuntimePoints,
                magnificationPercent: magnificationPercent
            )
        }

        return WorkspaceTerminalFontConfigurationSnapshot(
            configuredRuntimePoints: Float32(
                GhosttyConfig.loadForCmux(
                    globalFontMagnificationPercent:
                        magnificationPercent
                ).fontSize
            ),
            magnificationPercent: magnificationPercent
        )
    }

    func synchronizeThemeWithAppearance(_ appearance: NSAppearance?, source: String) {
        let synchronize: @MainActor () -> Void = {
            let (currentColorScheme, colorSchemeSource) =
                GhosttyConfig.appearanceSyncColorSchemePreference(
                    passedAppearance: appearance
                )
            self.synchronizeThemeWithResolvedAppearance(
                currentColorScheme,
                colorSchemeSource: colorSchemeSource,
                source: source
            )
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                synchronize()
            }
        } else {
            Task { @MainActor in
                synchronize()
            }
        }
    }

    private struct PendingAppearanceSynchronization {
        let colorScheme: GhosttyConfig.ColorSchemePreference
        let colorSchemeSource: String
        let source: String
    }

    @MainActor
    private func synchronizeThemeWithResolvedAppearance(
        _ currentColorScheme: GhosttyConfig.ColorSchemePreference,
        colorSchemeSource: String,
        source: String
    ) {
        let plan = Self.appearanceSynchronizationPlan(
            previousColorScheme: lastAppearanceColorScheme,
            currentColorScheme: currentColorScheme,
            isConfigurationReloadInProgress:
                configurationReloadCoordinator
                    .isReloadActive
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
                "appearance sync source=\(source) colorSchemeSource=\(colorSchemeSource) previous=\(previousLabel) current=\(currentLabel) reload=\(plan.shouldReloadConfiguration)"
            )
        }
        switch plan {
        case .unchanged:
            return
        case let .deferred(colorScheme):
            pendingAppearanceSynchronization = PendingAppearanceSynchronization(
                colorScheme: colorScheme,
                colorSchemeSource: colorSchemeSource,
                source: source
            )
            if backgroundLogEnabled {
                logBackground("appearance sync deferred source=\(source)")
            }
            return
        case let .reload(colorScheme, runtimeColorScheme):
            synchronizeGhosttyRuntimeColorScheme(
                runtimeColorScheme,
                colorScheme: colorScheme,
                source: source
            )
            reloadConfiguration(
                source: "appearanceSync:\(source)",
                reloadSettingsFromFile: false,
                preferredColorScheme: colorScheme
            )
        }
    }

    @MainActor
    private func drainPendingAppearanceSynchronization() {
        guard !configurationReloadCoordinator
                .isReloadActive,
              let pendingAppearanceSynchronization else { return }
        self.pendingAppearanceSynchronization = nil
        synchronizeThemeWithResolvedAppearance(
            pendingAppearanceSynchronization.colorScheme,
            colorSchemeSource: pendingAppearanceSynchronization.colorSchemeSource,
            source: pendingAppearanceSynchronization.source
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
        guard nativeReloadActionSuppressionDepth == 0,
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

        applyDefaultBackground(
            defaultBackgroundValues(from: config),
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
        let resolvedCursor = ghosttyColorValue(
            from: config,
            key: "cursor-color",
            fallback: resolvedForeground
        )
        let resolvedCursorText = ghosttyColorValue(
            from: config,
            key: "cursor-text",
            fallback: resolvedColor
        )
        let resolvedSelectionBackground = ghosttyColorValue(
            from: config,
            key: "selection-background",
            fallback: resolvedForeground
        )
        let resolvedSelectionForeground = ghosttyColorValue(
            from: config,
            key: "selection-foreground",
            fallback: resolvedColor
        )
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

    private func resolvedDefaultBackgroundValues(
        preferredColorScheme:
            GhosttyConfig.ColorSchemePreference,
        baselineConfig: ghostty_config_t?,
        useOnDiskResolvedConfig: Bool = true
    ) -> DefaultBackgroundValues {
        let baseline =
            defaultBackgroundValues(from: baselineConfig)
        guard useOnDiskResolvedConfig else {
            return baseline
        }
        let resolved = GhosttyConfig.loadForCmux(
            preferredColorScheme: preferredColorScheme,
            useCache: false,
            globalFontMagnificationPercent:
                GlobalFontMagnification.storedPercent
        )
        let fallbackForUnspecified =
            Self
                .shouldIgnoreNativeLegacyBaselineForUnparsedAppearance()
            ? defaultBackgroundValues(from: nil)
            : baseline
        return DefaultBackgroundValues(
            backgroundColor: resolvedAppearanceValue(
                parsedValue: resolved.backgroundColor,
                baselineValue: baseline.backgroundColor,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.backgroundColor,
                hasParsedDirective:
                    resolved.hasParsedBackgroundColor,
                hasDirective:
                    resolved.hasBackgroundColorDirective
            ),
            backgroundOpacity: resolvedAppearanceValue(
                parsedValue: resolved.backgroundOpacity,
                baselineValue: baseline.backgroundOpacity,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.backgroundOpacity,
                hasParsedDirective:
                    resolved.hasParsedBackgroundOpacity,
                hasDirective:
                    resolved.hasBackgroundOpacityDirective
            ),
            backgroundBlur: resolvedAppearanceValue(
                parsedValue: resolved.backgroundBlur,
                baselineValue: baseline.backgroundBlur,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.backgroundBlur,
                hasParsedDirective:
                    resolved.hasParsedBackgroundBlur,
                hasDirective:
                    resolved.hasBackgroundBlurDirective
            ),
            foregroundColor: resolvedAppearanceValue(
                parsedValue: resolved.foregroundColor,
                baselineValue: baseline.foregroundColor,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.foregroundColor,
                hasParsedDirective:
                    resolved.hasParsedForegroundColor,
                hasDirective:
                    resolved.hasForegroundColorDirective
            ),
            cursorColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorColor,
                baselineValue: baseline.cursorColor,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.cursorColor,
                hasParsedDirective:
                    resolved.hasParsedCursorColor,
                hasDirective:
                    resolved.hasCursorColorDirective
            ),
            cursorTextColor: resolvedAppearanceValue(
                parsedValue: resolved.cursorTextColor,
                baselineValue: baseline.cursorTextColor,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.cursorTextColor,
                hasParsedDirective:
                    resolved.hasParsedCursorTextColor,
                hasDirective:
                    resolved.hasCursorTextColorDirective
            ),
            selectionBackground: resolvedAppearanceValue(
                parsedValue: resolved.selectionBackground,
                baselineValue: baseline.selectionBackground,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.selectionBackground,
                hasParsedDirective:
                    resolved.hasParsedSelectionBackground,
                hasDirective:
                    resolved.hasSelectionBackgroundDirective
            ),
            selectionForeground: resolvedAppearanceValue(
                parsedValue: resolved.selectionForeground,
                baselineValue: baseline.selectionForeground,
                unspecifiedFallbackValue:
                    fallbackForUnspecified.selectionForeground,
                hasParsedDirective:
                    resolved.hasParsedSelectionForeground,
                hasDirective:
                    resolved.hasSelectionForegroundDirective
            )
        )
    }

    private func updateDefaultBackgroundFromResolvedGhosttyConfig(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference,
        baselineConfig: ghostty_config_t?,
        scope: GhosttyDefaultBackgroundUpdateScope = .unscoped,
        useOnDiskResolvedConfig: Bool = true,
        forceNotify: Bool = false
    ) {
        applyDefaultBackground(
            resolvedDefaultBackgroundValues(
                preferredColorScheme: preferredColorScheme,
                baselineConfig: baselineConfig,
                useOnDiskResolvedConfig:
                    useOnDiskResolvedConfig
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

    @MainActor
    private func ringBell(surface: TerminalSurface?) {
        let features = bellFeatures()
        let customAudioEnabled = (features & (1 << 1)) != 0
        ringBell(
            surface: surface,
            presentation: TerminalBellPresentation(
                systemSoundEnabled: (features & (1 << 0)) != 0,
                customAudioPath: customAudioEnabled ? bellAudioPath() : nil,
                customAudioVolume: customAudioEnabled ? bellAudioVolume() : 0.5,
                visualBellEnabled: (features & (1 << 2)) != 0
            )
        )
    }

    /// Presents one terminal bell without exposing process-level attention.
    @MainActor
    func ringBell(
        surface: TerminalSurface?,
        presentation: TerminalBellPresentation
    ) {
        terminalBellService.ring(
            presentation: presentation
        )
        if presentation.visualBellEnabled {
            surface?.onVisualBell?()
        }
    }

    private func applyDefaultBackground(
        _ values: DefaultBackgroundValues,
        source: String,
        scope: GhosttyDefaultBackgroundUpdateScope,
        forceNotify: Bool = false
    ) {
        applyDefaultBackground(
            color: values.backgroundColor,
            opacity: values.backgroundOpacity,
            backgroundBlur: values.backgroundBlur,
            foregroundColor: values.foregroundColor,
            cursorColor: values.cursorColor,
            cursorTextColor: values.cursorTextColor,
            selectionBackground: values.selectionBackground,
            selectionForeground: values.selectionForeground,
            source: source,
            scope: scope,
            forceNotify: forceNotify
        )
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

    func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
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

    static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
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
                // Ghostty's desktop-notification action is surface-originated;
                // its native macOS host deliberately treats an app target as a no-op.
                return true
            }

            if action.tag == GHOSTTY_ACTION_RING_BELL {
                performOnMain {
                    self.ringBell(surface: nil)
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
            return handleChildExitedAction(
                runtimeSurface: callbackContext?.terminalSurface,
                tabId: callbackTabId,
                surfaceId: callbackSurfaceId,
                message: action.action.child_exited
            )
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
                self.ringBell(
                    surface: callbackContext?.terminalSurface
                        ?? surfaceView.terminalSurface
                )
            }
            return true
        case GHOSTTY_ACTION_SELECTION_CHANGED:
            surfaceView.selectionAccessibilitySignal.request()
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let gotoDirection = action.action.goto_split
            // Previous/next use cycle-based navigation through all panes in tree order
            if gotoDirection == GHOSTTY_GOTO_SPLIT_PREVIOUS || gotoDirection == GHOSTTY_GOTO_SPLIT_NEXT {
                guard let tabId = surfaceView.tabId else { return false }
                let forward = gotoDirection == GHOSTTY_GOTO_SPLIT_NEXT
                return performOnMain {
                    guard let app = AppDelegate.shared,
                          let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else { return false }
                    let result = tabManager.cycleSplitFocus(tabId: tabId, forward: forward)
#if DEBUG
                    if result {
                        GotoSplitCycleUITestSupport().recordCycleMoveIfNeeded(
                            tabManager: tabManager,
                            tabId: tabId,
                            forward: forward
                        )
                    }
#endif
                    return result
                }
            }
            // Directional navigation uses spatial positioning
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: gotoDirection) else {
                return false
            }
            return performOnMain {
                guard let app = AppDelegate.shared,
                      let tabManager = app.tabManagerFor(tabId: tabId) ?? app.tabManager else { return false }
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
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let url = GhosttySurfaceScrollView.linkHoverURL(from: action.action.mouse_over_link)
            let terminalSurface = surfaceView.terminalSurface
            DispatchQueue.main.async { guard surfaceView.terminalSurface === terminalSurface, surfaceView.isVisibleInUI else { return }; terminalSurface?.hostedView.setLinkHoverURL(url) }
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
            let terminalSurface = surfaceView.terminalSurface
            DispatchQueue.main.async {
                surfaceView.cellSize = cellSize
                _ = terminalSurface?.fontSizeLineageSnapshot()
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
            if let callbackContext,
               let tabId = callbackTabId {
                surfaceView.titleUpdateIngress.submit(
                    tabId: tabId,
                    surfaceId: callbackContext.surfaceId,
                    sourceSurfaceIdentifier: callbackContext.sourceSurfaceIdentifier,
                    terminalLifecycleID: callbackContext.terminalLifecycleID,
                    title: title,
                    titleOverride: callbackContext.titleOverride
                )
            }
            return true
        case GHOSTTY_ACTION_PWD:
            let pwdAction = action.action.pwd
            let geometry = pwdAction.scrollbar.map {
                NotificationScrollRestoreGeometry(
                    scrollbar: GhosttyScrollbar(c: $0.pointee),
                    rowSpaceRevision: pwdAction.scrollbar_revision
                )
            }
            handleCurrentDirectoryAction(
                pwdAction.pwd.flatMap { String(cString: $0) } ?? "",
                authoritativeGeometry: geometry,
                surfaceView: surfaceView
            )
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = callbackTabId ?? surfaceView.tabId,
                  let surfaceId = callbackSurfaceId ?? surfaceView.terminalSurface?.id else { return true }
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            desktopNotificationIngress.submit(GhosttyDesktopNotificationRequest(
                tabId: tabId,
                surfaceId: surfaceId,
                hookDirectory: surfaceView.currentDirectoryActionDispatcher.directorySnapshot()
                    ?? surfaceView.terminalSurface?.requestedWorkingDirectory,
                title: actionTitle,
                body: actionBody
            ))
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            let newColor = color(from: change)
            if let surfaceID = surfaceView.terminalSurface?.id { NotificationCenter.default.post(name: .ghosttySurfaceThemeDidChange, object: surfaceID) }
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
            let configChangeSurfaceID = surfaceView.terminalSurface?.id
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
                if let configChangeSurfaceID { NotificationCenter.default.post(name: .ghosttySurfaceThemeDidChange, object: configChangeSurfaceID) }
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
                GhosttySurfaceConfigurationRefresh.applyConfigurationReload(
                    to: target.target.surface,
                    soft: soft,
                    source: source,
                    redrawReason: "surface.reloadConfig",
                    reloadSurfaceConfiguration: { surface, soft, source in
                        self.reloadSurfaceConfiguration(
                            surface,
                            soft: soft,
                            source: source,
                            preferredColorScheme: preferredColorScheme
                        )
                    },
                    applySurfaceColorScheme: {
                        surfaceView.terminalSurface?.hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                            preferredColorScheme: preferredColorScheme
                        )
                    },
                    refreshHostBackground: {
                        surfaceView.terminalSurface?.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
                    },
                    forceRefresh: { reason in
                        surfaceView.terminalSurface?.forceRefresh(reason: reason)
                    }
                )
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
            let request = TerminalLinkOpenRequest(
                rawValue: urlString,
                sourceWorkspaceId: callbackTabId ?? surfaceView.tabId,
                sourcePanelId: callbackSurfaceId ?? surfaceView.terminalSurface?.id,
                workingDirectory: surfaceView.currentDirectoryActionDispatcher.directorySnapshot()
            )
            return performOnMain {
                surfaceView.recordCommandClickReleaseRuntimeOutcome(.openURL)
                return TerminalLinkOpenCoordinator().open(request)
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

    /// Resolves internal drag identity through the live registries. AppKit
    /// drag callbacks arrive on the main thread, while this view predates the
    /// app-wide MainActor annotation; the assumption keeps stale pasteboard
    /// UTIs from suppressing ordinary file drops without adding a second owner.
    private static func hasLiveInternalDrag(in pasteboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated {
            let app = AppDelegate.shared
            let types = pasteboard.types
            if types?.contains(tabTransferPasteboardType) == true,
               app?.liveTabDragCapabilityResolver.resolve(from: pasteboard) != nil {
                return true
            }
            guard types?.contains(sidebarTabReorderPasteboardType) == true else {
                return false
            }
            return SidebarTabDragPayload.hasLiveSession(
                in: pasteboard,
                currentSessionId: app?.sidebarWorkspaceDragRegistry.currentSessionId
            )
        }
    }

    private static func filteredDropTypes(_ types: [NSPasteboard.PasteboardType]) -> Set<NSPasteboard.PasteboardType> {
        Set(types).subtracting([tabTransferPasteboardType, sidebarTabReorderPasteboardType])
    }

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

    static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        AppDelegate.shared?.focusLog.append(message)
        #if DEBUG
        NSLog("[FOCUSDBG] %@", message)
        #endif
    }

    weak var terminalSurface: TerminalSurface?
    /// View-scoped ingress keeps title churn independent across terminal surfaces.
    fileprivate let titleUpdateIngress = GhosttyTitleUpdateIngress()
    /// Retained independently because the weak surface can clear before view teardown.
    private var titleUpdateSurfaceKey: GhosttyTitleUpdateSurfaceKey?
    // SAFETY: replay setup replaces this before runtime attachment; callbacks only read it.
    nonisolated(unsafe) var currentDirectoryActionDispatcher = GhosttyCurrentDirectoryActionDispatcher()
    var scrollbar: GhosttyScrollbar?
    /// Pending scrollbar value written from the action callback thread;
    /// read and cleared on the main thread by `flushPendingScrollbar()`.
    /// Access is guarded by `_scrollbarLock` because the action callback
    /// fires on Ghostty's I/O thread while the flush runs on main.
    private var _pendingScrollbar: GhosttyScrollbar?
    private var _scrollbarFlushScheduled = false
    private let _scrollbarLock = NSLock()
    private var _renderedFrameFlushScheduled = false
    private var _pendingRenderedFrameDeliveryReasons:
        TerminalRenderedFrameDeliveryReasons = []
    /// Pane-local frame demand lets a terminal-specific consumer observe a
    /// late render without enabling notifications on every terminal surface.
    let localRenderedFrameNotificationDemand = RenderDemandCounter()
    /// Copy-mode cursor demand stays local to this view and never publishes
    /// the shared rendered-frame notification.
    private let keyboardCopyModeRenderedFrameDemand = RenderDemandCounter()
    nonisolated let selectionAccessibilitySignal = TerminalSelectionAccessibilitySignal()
    private var selectionAccessibilityNotifier: TerminalSelectionAccessibilityNotifier?
    var cellSize: CGSize = .zero
    private var lastKnownMousePointInView: NSPoint?
    private let commandClickReleaseRouter = TerminalCommandClickReleaseRouter()
    private var commandClickReleaseRoutingActive = false
    private var commandClickReleaseRuntimeOutcome: TerminalCommandClickReleaseRouter.RuntimeOutcome?
    private var ghosttyMouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT
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
        let hasPending = _pendingScrollbar != nil
        _pendingScrollbar = nil
        _scrollbarLock.unlock()

        guard hasPending else { return }
        // Callback payloads are coalesced and can predate main-thread input.
        // Treat them as invalidation signals when the runtime is available so
        // a delayed packet can never move the viewport to obsolete geometry.
        guard let authoritativeScrollbar = authoritativeScrollbarSnapshot() else {
            // No runtime means the callback has no trustworthy row-space
            // identity. Drop it rather than moving AppKit to stale geometry.
            return
        }
        publishScrollbarUpdate(authoritativeScrollbar)
    }

    private func authoritativeScrollbarSnapshot() -> GhosttyScrollbar? {
        var value = ghostty_surface_scrollbar_s()
        guard readAuthoritativeScrollbar(&value) else { return nil }
        return GhosttyScrollbar(
            total: value.total,
            offset: value.offset,
            len: value.len
        )
    }

    private func publishScrollbarUpdate(
        _ value: GhosttyScrollbar,
        isAuthoritativeWheelResponse: Bool = false
    ) {
        scrollbar = value
        if keyboardCopyModeActive, let surface {
            reconcileKeyboardCopyModeViewport(surface: surface)
        }
        var userInfo: [AnyHashable: Any] = [GhosttyNotificationKey.scrollbar: value]
        if isAuthoritativeWheelResponse {
            userInfo[GhosttyNotificationKey.isAuthoritativeWheelResponse] = true
        }
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateScrollbar,
            object: self,
            userInfo: userInfo
        )
    }

    private func postWheelScroll(
        requiresAuthoritativeResponse: Bool,
        authoritativeResponseUnavailable: Bool = false
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if requiresAuthoritativeResponse {
            userInfo[GhosttyNotificationKey.requiresAuthoritativeWheelResponse] = true
        }
        if authoritativeResponseUnavailable {
            userInfo[GhosttyNotificationKey.authoritativeWheelResponseUnavailable] = true
        }
        NotificationCenter.default.post(
            name: .ghosttyDidReceiveWheelScroll,
            object: self,
            userInfo: userInfo.isEmpty ? nil : userInfo
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

    private func discardPendingScrollbar() {
        _scrollbarLock.lock()
        _pendingScrollbar = nil
        _scrollbarLock.unlock()
    }

    func enqueueRenderedFrameUpdate(
        reasons: TerminalRenderedFrameDeliveryReasons
    ) {
        guard !reasons.isEmpty else { return }
        _pendingRenderedFrameDeliveryReasons.formUnion(reasons)
        let needsSchedule = !_renderedFrameFlushScheduled
        if needsSchedule {
            _renderedFrameFlushScheduled = true
        }

        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            self?.flushRenderedFrameUpdate()
        }
    }

    private func flushRenderedFrameUpdate() {
        _renderedFrameFlushScheduled = false
        let reasons = _pendingRenderedFrameDeliveryReasons
        _pendingRenderedFrameDeliveryReasons = []

        if reasons.contains(.keyboardCopyModeCursor),
           keyboardCopyModeActive,
           let surface {
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        }
        if reasons.contains(.notification),
           renderedFrameNotificationDemandIsActive {
            NotificationCenter.default.post(
                name: .ghosttyDidRenderFrame,
                object: self
            )
        }
    }

    var desiredFocus: Bool = false
    var suppressingReparentFocus: Bool = false
    var tabId: UUID?
    var selectionTranslationHostView: NSView?
    var firstResponderFocusTransactionId: UUID?
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
    private var manualNamedKeyConsumedKeyUps: Set<UInt16> = []
    /// Deferred native input actions retain their authored order until the
    /// runtime surface is ready. Keeping paste and key actions in one queue
    /// prevents a later key from overtaking an earlier cold paste.
    private enum PendingInputReplayAction {
        case keyDown(NSEvent)
        case keyUp(NSEvent)
        case paste(UUID)
    }
    private var pendingInputReplayActions: [PendingInputReplayAction] = []
    private var pendingKeyDownActionCount = 0
    private var pendingKeyActionCount = 0
    private var pendingPasteActionCount = 0
    /// Surface identity that owns deferred key actions. Portal reuse can
    /// attach a different terminal before the original runtime is ready; never
    /// replay the old terminal's input into that replacement.
    private var pendingExplicitKeyDownSurfaceID: UUID?
    private weak var pendingExplicitKeyDownSurface: TerminalSurface?
    private var pendingExplicitKeyDownKeyCodes: [UInt16: Int] = [:]
    private weak var pendingPasteSurface: TerminalSurface?
    private var pendingPasteSurfaceID: UUID?
    private var pendingPastePayloadBytes = 0
    private var pendingPastePayloadBytesByID: [UUID: Int] = [:]
    private struct PendingPastePreparationResult: Sendable {
        let payload: TerminalImageTransferPreparedContent
        let payloadBytes: Int
    }
    private var pendingPastePreparationTasks: [
        UUID: Task<PendingPastePreparationResult, Never>
    ] = [:]
    private var pendingPastePreparedPayloadsByID: [UUID: TerminalImageTransferPreparedContent] = [:]
    private static let maximumPendingExplicitKeyDownEvents = 32
    private static let maximumPendingPasteActions = 32
    private static let maximumPendingInputReplayActions =
        maximumPendingExplicitKeyDownEvents + maximumPendingPasteActions
    private static let maximumPendingPastePayloadBytes = 4 * 1_048_576
    private var replayingPendingInput = false
    private var keyboardCopyModeInputState = TerminalKeyboardCopyModeInputState()
    private var keyboardCopyModeCursor: TerminalKeyboardCopyModeCursor?
    private var keyboardCopyModeRenderedFrameDemandRelease: (() -> Void)?
    private var keyboardCopyModeSelectionKind: KeyboardCopyModeSelectionKind?
    private var keyboardCopyModeVisualActive: Bool { keyboardCopyModeSelectionKind != nil }
    private var keyboardCopyModeVisualLineActive: Bool { keyboardCopyModeSelectionKind == .line }
    let keyboardCopyModeCursorOverlayView: NSView = GhosttyFlashOverlayView(frame: .zero)
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
    /// Installed only while this surface owns a button session. Keeping the
    /// mouse-up monitor demand-driven avoids fan-out across every terminal
    /// view for ordinary clicks elsewhere in the window.
    private var mouseUpEventMonitor: Any?
    /// Observes releases delivered outside cmux while a terminal owns a
    /// button session. Demand-driven: installed only while sessions exist.
    private var globalMouseUpEventMonitor: Any?
    private var applicationResignActiveObserver: NSObjectProtocol?
    private var contextMenuEndObserver: NSObjectProtocol?
    nonisolated let terminalClipboardInputSequencer =
        TerminalClipboardInputSequencer<ClipboardDeferredInput, UInt>(
            maximumBufferedEvents: 256,
            maximumBufferedCost: 1_048_576
        )
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var windowOcclusionObserver: NSObjectProtocol?
    private var windowKeyObservers: [NSObjectProtocol] = []
    /// Windows that have reported an occlusion `.visible` bit at least once, so the
    /// visibility rule knows when that signal is trustworthy (see
    /// `TerminalRendererWindowVisibility`). Weak: windows come and go.
    private static let windowsThatReportedVisible = NSHashTable<NSWindow>.weakObjects()
    private var lastScrollEventTime: CFTimeInterval = 0
    private let scrollSpeedAccumulator = TerminalScrollSpeedAccumulator()
    private var visibleInUI: Bool = true
    private var pendingSurfaceSize: CGSize?
    private var deferredSurfaceSizeRetryQueued = false, needsSurfaceSizeRetryAfterMetalLayerRealizes = false
    private var deferredSurfaceSizeNonMetalRetryCount = 0
    private var lastDrawableSize: CGSize = .zero
    private var isFindEscapeSuppressionArmed = false
    private typealias TrackedMouseButton = GhosttyMouseSessionLedger.Button
    private typealias RememberedGhosttyMouseState = GhosttyMouseSessionLedger.PointerState
    /// The surface view is the sole owner of Ghostty button-session state.
    /// AppKit forwarding and clipboard sequencing feed this ledger rather than
    /// maintaining independent pressed-button mirrors.
    private let ghosttyMouseSessionLedger = GhosttyMouseSessionLedger()
    /// Compatibility projection for the find overlay; ownership remains in
    /// the surface ledger rather than a second mutable flag.
    private var hasPendingLeftMouseRelease: Bool {
        ghosttyMouseSessionLedger.hasSession(
            for: .left,
            on: currentGhosttyMouseSurfaceIdentity
        )
    }
    /// Lifecycle cleanup runs after the current AppKit/SwiftUI callback so a
    /// potentially blocking Ghostty release never stalls portal reconciliation.
    /// The captured session tokens keep the task safe across a new press or
    /// native runtime generation.
    private var deferredGhosttyMouseRepairTask: Task<Void, Never>?
    let imageTransferPreparation: TerminalImageTransferPreparationService?
#if DEBUG
    private var lastSizeSkipSignature: String?
#endif
    private static let maxDeferredSurfaceSizeNonMetalRetryCount = 8

    private var hasUsableFocusGeometry: Bool { bounds.width > 1 && bounds.height > 1 }

    var hasClipboardInputDeferral: Bool {
        terminalClipboardInputSequencer.hasInputDeferral(
            for: terminalSurface?.runtimeSurfaceGeneration ?? .max
        )
    }

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
        imageTransferPreparation = nil
        super.init(frame: frameRect)
        setup()
    }

    init(
        frame frameRect: NSRect,
        imageTransferPreparation: TerminalImageTransferPreparationService
    ) {
        self.imageTransferPreparation = imageTransferPreparation
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        imageTransferPreparation = nil
        super.init(coder: coder)
        setup()
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = GhosttyMetalLayer(
            renderDemand: GhosttyApp.renderedFrameNotificationDemand,
            localRenderDemand: localRenderedFrameNotificationDemand,
            keyboardCopyModeCursorDemand: keyboardCopyModeRenderedFrameDemand,
            receiver: self
        )
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
        selectionAccessibilityNotifier = TerminalSelectionAccessibilityNotifier(element: self, events: selectionAccessibilitySignal.events)
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
        keyboardCopyModeCursorOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        keyboardCopyModeCursorOverlayView.layer?.borderColor = NSColor.controlAccentColor.cgColor
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel]
        ) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func installMouseUpEventMonitorIfNeeded() {
        guard mouseUpEventMonitor == nil else { return }
        mouseUpEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            guard let self,
                  !self.ghosttyMouseSessionLedger.activeButtons.isEmpty else {
                return event
            }
            return self.localEventMouseUp(event)
        }
        globalMouseUpEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            self?.globalMouseUpEvent(event)
        }
        applicationResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deferReleaseAllGhosttyMouseButtons(reason: "applicationDidResignActive")
        }
    }

    private func removeMouseUpEventMonitorIfUnused() {
        guard ghosttyMouseSessionLedger.activeButtons.isEmpty else { return }
        if let mouseUpEventMonitor {
            NSEvent.removeMonitor(mouseUpEventMonitor)
            self.mouseUpEventMonitor = nil
        }
        if let globalMouseUpEventMonitor {
            NSEvent.removeMonitor(globalMouseUpEventMonitor)
            self.globalMouseUpEventMonitor = nil
        }
        if let applicationResignActiveObserver {
            NotificationCenter.default.removeObserver(applicationResignActiveObserver)
            self.applicationResignActiveObserver = nil
        }
    }

    private func globalMouseUpEvent(_ event: NSEvent) {
        guard let button = TrackedMouseButton(mouseUpEvent: event),
              ghosttyMouseSessionLedger.hasSession(
                  for: button,
                  on: currentGhosttyMouseSurfaceIdentity
              ),
              !hasClipboardInputDeferral else {
            return
        }
        // Global monitor callbacks have no view-local coordinate space. Keep
        // the ledger's last point and release only the matching session token.
        deferGhosttyMouseButtonRepair(
            reason: "globalMouseUp.\(button.rawValue)",
            forceButtons: Set([button])
        )
    }

    private func removeContextMenuEndObserver() {
        guard let contextMenuEndObserver else { return }
        NotificationCenter.default.removeObserver(contextMenuEndObserver)
        self.contextMenuEndObserver = nil
    }

    private func observeContextMenuEnd(
        _ menu: NSMenu,
        session: GhosttyMouseSessionLedger.Session
    ) {
        removeContextMenuEndObserver()
        contextMenuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.removeContextMenuEndObserver()
            self.releaseContextMenuMouseSession(session)
        }
    }

    private func releaseContextMenuMouseSession(
        _ session: GhosttyMouseSessionLedger.Session
    ) {
        guard session.button == .right else { return }
        guard let terminalSurface,
              let surfaceIdentity = currentGhosttyMouseSurfaceIdentity else {
            resetGhosttyMouseButtonTracking()
            return
        }
        guard ghosttyMouseSessionLedger.session(
            for: .right,
            on: surfaceIdentity
        ) == session else { return }
        guard let surface = terminalSurface.liveSurfaceForGhosttyAccess(
            reason: "contextMenuMouseRelease"
        ),
        UInt(bitPattern: surface) == session.surface.nativeAddress,
        currentGhosttyMouseSurfaceIdentity == surfaceIdentity else {
            resetGhosttyMouseButtonTracking()
            return
        }
        let mods = ghosttyMouseSessionLedger.pointerState?.mods ?? GHOSTTY_MODS_NONE
        _ = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: mods
        )
        _ = finishGhosttyMouseSession(session)
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return localEventMouseUp(event)
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

    private func localEventMouseUp(_ event: NSEvent) -> NSEvent? {
        guard let button = TrackedMouseButton(mouseUpEvent: event) else {
            return event
        }
        let currentSurfaceIdentity = currentGhosttyMouseSurfaceIdentity
        guard ghosttyMouseSessionLedger.hasSession(
            for: button,
            on: currentSurfaceIdentity
        ) else {
            // Only synchronize when this view's active session belongs to a
            // replaced/detached runtime; unrelated button-ups stay constant
            // time even while several terminal views are alive.
            if ghosttyMouseSessionLedger.activeSurface != currentSurfaceIdentity {
                synchronizeGhosttyMouseSurfaceIdentity()
            }
            return event
        }
        // The normal mouse-up path is buffered while a sequenced clipboard
        // read is in flight. Let that event replay in order instead of
        // synthesizing a release ahead of the queued gesture.
        guard !hasClipboardInputDeferral else { return event }

        // A same-window mouse-up must continue through AppKit's responder
        // path. In particular, command-click release routing needs to run on
        // ``mouseUp(with:)``; repairing here would consume the release before
        // that path can resolve links. The next non-drag event reconciles a
        if event.window == window, button == .left {
            // Keep the event for command-click handling, then verify the same
            // generation on the next main-actor turn. If the responder or
            // overlay drops the up, the token is still active and is released;
            // a normally handled up has already consumed the token. Right
            // button releases are deliberately excluded: AppKit may enter
            // menu tracking immediately after the down, and a deferred
            // synthetic release must not run before `didEndTracking`.
            deferGhosttyMouseButtonRepair(
                reason: "localMouseUp.postDispatch.\(button.rawValue)",
                forceButtons: Set([button])
            )
        } else {
            // An out-of-window release has no normal responder path. Preserve
            // the last point and repair this generation immediately.
            reconcileGhosttyMouseButtons(
                reason: "localMouseUp.\(button.rawValue)",
                forceButtons: Set([button])
            )
        }
        return event
    }

    @discardableResult
    private func markGhosttyMouseButtonPressed(_ button: TrackedMouseButton) -> UInt64 {
        guard let surfaceIdentity = currentGhosttyMouseSurfaceIdentity,
              let session = ghosttyMouseSessionLedger.begin(
                  button,
                  on: surfaceIdentity
              ) else {
            return 0
        }
        installMouseUpEventMonitorIfNeeded()
        return session.generation
    }

    @discardableResult
    private func finishGhosttyMouseSession(
        _ session: GhosttyMouseSessionLedger.Session
    ) -> Bool {
        let finished = ghosttyMouseSessionLedger.finish(session)
        removeMouseUpEventMonitorIfUnused()
        if session.button == .right {
            removeContextMenuEndObserver()
        }
        return finished
    }

    private func resetGhosttyMouseButtonTracking() {
        ghosttyMouseSessionLedger.invalidate()
        removeMouseUpEventMonitorIfUnused()
        removeContextMenuEndObserver()
    }

    func attachSurface(_ surface: TerminalSurface) {
        let isSameSurface = terminalSurface === surface
        let isAlreadyAttached = surface.isAttached(to: self)
        let nextTitleUpdateSurfaceKey = GhosttyTitleUpdateSurfaceKey(
            surfaceId: surface.id,
            sourceSurface: surface
        )
        if titleUpdateSurfaceKey != nextTitleUpdateSurfaceKey {
            if titleUpdateSurfaceKey != nil {
                titleUpdateIngress.retireCurrentAttachment()
            }
            titleUpdateSurfaceKey = nextTitleUpdateSurfaceKey
        }
        let currentMouseSurfaceIdentity = currentGhosttyMouseSurfaceIdentity
        let nextMouseSurfaceIdentity = ghosttyMouseSurfaceIdentity(for: surface)
        if !isSameSurface {
            if pendingKeyActionCount > 0,
               (pendingExplicitKeyDownSurface !== surface
                || pendingExplicitKeyDownSurfaceID != surface.id) {
                discardPendingExplicitKeyDownEvents()
            }
            if pendingPasteActionCount > 0,
               (pendingPasteSurface !== surface
                || pendingPasteSurfaceID != surface.id) {
                discardPendingPasteAfterSurfaceReady()
            }
            appliedColorScheme = nil
            // Finish any sessions that still belong to the old surface before
            // replacing the view's surface owner.
            releaseAllGhosttyMouseButtonsSynchronously(reason: "attachSurface")
            resetGhosttyMouseButtonTracking()
            // Reset any OSC 22 mouse shape carried over from the previous surface.
            updateGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        } else if currentMouseSurfaceIdentity != nextMouseSurfaceIdentity {
            // A TerminalSurface can rebuild its native pointer without being
            // replaced. Never send an old session to the replacement pointer.
            resetGhosttyMouseButtonTracking()
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
        synchronizeGhosttyMouseSurfaceIdentity()
    }

    private func queueExplicitKeyDownForInputDemand(_ event: NSEvent) {
        guard let owningSurface = terminalSurface else { return }
        guard pendingKeyDownActionCount < Self.maximumPendingExplicitKeyDownEvents,
              pendingInputReplayActions.count < Self.maximumPendingInputReplayActions else {
            return
        }
        if pendingKeyActionCount == 0 {
            pendingExplicitKeyDownSurfaceID = owningSurface.id
            pendingExplicitKeyDownSurface = owningSurface
        } else if pendingExplicitKeyDownSurface !== owningSurface {
            discardPendingExplicitKeyDownEvents()
            return
        }
        pendingInputReplayActions.append(.keyDown(event))
        pendingKeyDownActionCount += 1
        pendingKeyActionCount += 1
        pendingExplicitKeyDownKeyCodes[event.keyCode, default: 0] += 1
    }

    fileprivate func replayPendingExplicitKeyDownEventsIfReady() {
        replayPendingInputIfReady()
    }

    fileprivate func discardPendingExplicitKeyDownEvents() {
        removePendingInputReplayActions { action in
            switch action {
            case .keyDown, .keyUp:
                return true
            case .paste:
                return false
            }
        }
        pendingExplicitKeyDownSurfaceID = nil
        pendingExplicitKeyDownSurface = nil
        pendingExplicitKeyDownKeyCodes.removeAll(keepingCapacity: false)
    }

    @discardableResult
    fileprivate func queuePasteAfterSurfaceReady(for surface: TerminalSurface) -> Bool {
        if pendingPasteSurface !== surface {
            discardPendingPasteAfterSurfaceReady()
        }
        guard pendingPasteActionCount < Self.maximumPendingPasteActions,
              pendingInputReplayActions.count < Self.maximumPendingInputReplayActions,
              let pasteboard = GhosttyApp.terminalPasteboard.pasteboard(
                  for: GHOSTTY_CLIPBOARD_STANDARD
              ),
              let preparationService = imageTransferPreparation else {
            return false
        }
        pendingPasteSurface = surface
        pendingPasteSurfaceID = surface.id

        // Capture the pasteboard generation while the user gesture is being
        // handled, then let the killable preparation worker materialize it off
        // the main actor. The worker rejects a generation that changed before
        // it could be read instead of replaying a later clipboard value.
        let request = TerminalPasteboardReadRequest(
            pasteboardName: pasteboard.name.rawValue,
            changeCount: pasteboard.changeCount
        )
        let preparationID = UUID()
        pendingInputReplayActions.append(.paste(preparationID))
        pendingPasteActionCount += 1
        let pasteboardService = GhosttyApp.terminalPasteboard
        let preparationTask = Task.detached(priority: .utility) {
            let payload = await preparationService.prepare(
                request: request,
                mode: .paste
            )
            return PendingPastePreparationResult(
                payload: payload,
                payloadBytes: GhosttyNSView.pendingPastePayloadByteCount(
                    payload,
                    using: pasteboardService
                )
            )
        }
        pendingPastePreparationTasks[preparationID] = preparationTask
        let surfaceID = surface.id
        Task { @MainActor [weak self] in
            let result = await preparationTask.value
            if let self {
                self.completePendingPastePreparation(
                    preparationID: preparationID,
                    surfaceID: surfaceID,
                    result: result
                )
            } else {
                result.payload.cleanupTransferredTemporaryFiles(
                    using: GhosttyApp.terminalPasteboard
                )
            }
        }
        return true
    }

    fileprivate func discardPendingPasteAfterSurfaceReady() {
        for task in pendingPastePreparationTasks.values {
            task.cancel()
        }
        pendingPastePreparationTasks.removeAll(keepingCapacity: false)
        for payload in pendingPastePreparedPayloadsByID.values {
            payload.cleanupTransferredTemporaryFiles(
                using: GhosttyApp.terminalPasteboard
            )
        }
        pendingPastePreparedPayloadsByID.removeAll(keepingCapacity: false)
        removePendingInputReplayActions { action in
            if case .paste = action { return true }
            return false
        }
        pendingPasteSurface = nil
        pendingPasteSurfaceID = nil
        pendingPastePayloadBytes = 0
        pendingPastePayloadBytesByID.removeAll(keepingCapacity: false)
    }

    private func completePendingPastePreparation(
        preparationID: UUID,
        surfaceID: UUID,
        result: PendingPastePreparationResult
    ) {
        let payload = result.payload
        pendingPastePreparationTasks.removeValue(forKey: preparationID)
        guard pendingInputReplayActions.contains(where: { action in
            if case .paste(let actionID) = action {
                return actionID == preparationID
            }
            return false
        }) else {
            payload.cleanupTransferredTemporaryFiles(
                using: GhosttyApp.terminalPasteboard
            )
            return
        }
        guard pendingPasteSurface?.id == surfaceID,
              pendingPasteSurfaceID == surfaceID else {
            removePendingInputReplayActions { action in
                if case .paste(let actionID) = action {
                    return actionID == preparationID
                }
                return false
            }
            payload.cleanupTransferredTemporaryFiles(
                using: GhosttyApp.terminalPasteboard
            )
            return
        }

        if payload != .reject {
            let payloadBytes = result.payloadBytes
            guard payloadBytes <= Self.maximumPendingPastePayloadBytes,
                  pendingPastePayloadBytes <=
                      Self.maximumPendingPastePayloadBytes - payloadBytes else {
                payload.cleanupTransferredTemporaryFiles(
                    using: GhosttyApp.terminalPasteboard
                )
                pendingPastePreparedPayloadsByID[preparationID] = .reject
                replayPendingInputIfReady()
                return
            }
            pendingPastePayloadBytes += payloadBytes
            pendingPastePayloadBytesByID[preparationID] = payloadBytes
        }
        pendingPastePreparedPayloadsByID[preparationID] = payload
        replayPendingInputIfReady()
    }

    fileprivate func replayPendingPasteAfterSurfaceReadyIfNeeded() {
        replayPendingInputIfReady()
    }

    fileprivate func replayPendingInputIfReady() {
        guard !pendingInputReplayActions.isEmpty,
              let readySurface = terminalSurface,
              surface != nil else {
            return
        }
        let keySurfaceMatches = pendingKeyActionCount == 0
            ? true
            : pendingExplicitKeyDownSurface === readySurface
                && pendingExplicitKeyDownSurfaceID == readySurface.id
        let pasteSurfaceMatches = pendingPasteActionCount == 0
            ? true
            : pendingPasteSurface === readySurface
                && pendingPasteSurfaceID == readySurface.id
        guard keySurfaceMatches, pasteSurfaceMatches else {
            discardPendingExplicitKeyDownEvents()
            discardPendingPasteAfterSurfaceReady()
            return
        }

        replayingPendingInput = true
        defer {
            replayingPendingInput = false
            if pendingKeyActionCount == 0 {
                pendingExplicitKeyDownSurfaceID = nil
                pendingExplicitKeyDownSurface = nil
                pendingExplicitKeyDownKeyCodes.removeAll(keepingCapacity: false)
            }
            if pendingPasteActionCount == 0 {
                pendingPasteSurface = nil
                pendingPasteSurfaceID = nil
                pendingPastePayloadBytes = 0
                pendingPastePayloadBytesByID.removeAll(keepingCapacity: false)
            }
        }

        while let action = pendingInputReplayActions.first {
            guard terminalSurface === readySurface, surface != nil else {
                discardPendingExplicitKeyDownEvents()
                discardPendingPasteAfterSurfaceReady()
                return
            }

            switch action {
            case .keyDown(let event):
                _ = removeFirstPendingInputReplayAction()
                let remainingKeyDowns =
                    (pendingExplicitKeyDownKeyCodes[event.keyCode] ?? 1) - 1
                if remainingKeyDowns > 0 {
                    pendingExplicitKeyDownKeyCodes[event.keyCode] = remainingKeyDowns
                } else {
                    pendingExplicitKeyDownKeyCodes.removeValue(
                        forKey: event.keyCode
                    )
                }
                keyDown(with: event)
            case .keyUp(let event):
                _ = removeFirstPendingInputReplayAction()
                keyUp(with: event)
            case .paste(let preparationID):
                guard let payload = pendingPastePreparedPayloadsByID[
                    preparationID
                ] else {
                    // Preserve the authored order until this preparation
                    // completes; later key events must not overtake it.
                    return
                }
                _ = removeFirstPendingInputReplayAction()
                pendingPastePreparedPayloadsByID.removeValue(
                    forKey: preparationID
                )
                if let payloadBytes = pendingPastePayloadBytesByID.removeValue(
                    forKey: preparationID
                ) {
                    pendingPastePayloadBytes = max(
                        0,
                        pendingPastePayloadBytes - payloadBytes
                    )
                }
                if !executePreparedImageTransfer(
                    payload,
                    mode: .paste,
                    onCancel: {}
                ) {
                    payload.cleanupTransferredTemporaryFiles(
                        using: GhosttyApp.terminalPasteboard
                    )
                }
            }
        }
    }

    @discardableResult
    private func removeFirstPendingInputReplayAction() -> PendingInputReplayAction {
        let action = pendingInputReplayActions.removeFirst()
        switch action {
        case .keyDown:
            pendingKeyDownActionCount = max(0, pendingKeyDownActionCount - 1)
            pendingKeyActionCount = max(0, pendingKeyActionCount - 1)
        case .keyUp:
            pendingKeyActionCount = max(0, pendingKeyActionCount - 1)
        case .paste:
            pendingPasteActionCount = max(0, pendingPasteActionCount - 1)
        }
        return action
    }

    private func removePendingInputReplayActions(
        where shouldRemove: (PendingInputReplayAction) -> Bool
    ) {
        pendingInputReplayActions.removeAll(where: shouldRemove)
        pendingKeyDownActionCount = 0
        pendingKeyActionCount = 0
        pendingPasteActionCount = 0
        for action in pendingInputReplayActions {
            switch action {
            case .keyDown:
                pendingKeyDownActionCount += 1
                pendingKeyActionCount += 1
            case .keyUp:
                pendingKeyActionCount += 1
            case .paste:
                pendingPasteActionCount += 1
            }
        }
    }

    private nonisolated static func pendingPastePayloadByteCount(
        _ payload: TerminalImageTransferPreparedContent,
        using pasteboardService: TerminalPasteboardService
    ) -> Int {
        switch payload {
        case .insertText(let text):
            return text.utf8.count
        case .fileURLs(let urls):
            return urls.reduce(into: 0) { total, url in
                guard total != .max else { return }
                var payloadBytes = url.path.utf8.count
                if pasteboardService.isOwnedTemporaryImageFile(url) {
                    let maybeFileSize = try? url.resourceValues(
                        forKeys: [.fileSizeKey]
                    ).fileSize
                    guard let fileSize = maybeFileSize,
                          fileSize >= 0 else {
                        total = .max
                        return
                    }
                    let (withFileSize, fileSizeOverflowed) = payloadBytes
                        .addingReportingOverflow(fileSize)
                    guard !fileSizeOverflowed else {
                        total = .max
                        return
                    }
                    payloadBytes = withFileSize
                }
                let (next, overflowed) = total.addingReportingOverflow(payloadBytes)
                total = overflowed ? .max : next
            }
        case .reject:
            return 0
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            // AppKit invokes this lifecycle edge on the UI thread before the
            // view can be deallocated. Release the native gesture here, while
            // the owning surface is still available; deinit only performs
            // nonisolated observer/ledger cleanup.
            releaseAllGhosttyMouseButtonsSynchronously(reason: "viewWillMoveToWindow.nil")
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
            self.windowOcclusionObserver = nil
        }
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowKeyObservers.removeAll()
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
        guard let window else {
            deferReleaseAllGhosttyMouseButtons(
                reason: "viewDidMoveToWindow.nil"
            )
            return
        }

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

        // Window-level occlusion (miniaturized, fully covered, inactive Space)
        // pauses the core renderer and lets the reclamation controller release
        // this surface's GPU swap chain. View-level occlusion stays untouched:
        // a nil-window reparenting transition keeps the last window state, so
        // portal moves cannot flap occlusion mid-drag.
        windowOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let occludedWindow = notification.object as? NSWindow else { return }
            // Delivered on the main queue (`queue: .main`), which is the main actor.
            MainActor.assumeIsolated {
                self?.applyRendererWindowVisibility(for: occludedWindow)
            }
        }
        // Key/main transitions do not always come with an occlusion change, and a
        // window on a virtual display may never report `.visible` at all; both
        // re-evaluate the same rule so an on-screen window is always presented.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didResignKeyNotification] {
            windowKeyObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let keyWindow = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.applyRendererWindowVisibility(for: keyWindow)
                }
            })
        }
        applyRendererWindowVisibility(for: window)

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        // The portal seeds the complete outer/inner geometry before reparenting.
        // A move-to-window callback is part of that hierarchy mutation; forcing
        // either the portal host or this subtree to lay out here recursively
        // enters the hierarchy while AppKit is still moving it on macOS 15.
        // Consume the committed bounds and let the portal's queued convergence
        // pass handle any later geometry change.
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
        // Intentionally no-op at the VIEW level: view visibility flaps during
        // portal reparenting and would cause transient clears. Occlusion is
        // driven by portal visibility (`setVisibleInUI`) combined with the
        // window-level observer registered in `viewDidMoveToWindow`.
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
        let pasteboard = NSPasteboard(name: .drag)
        return hasLiveInternalDrag(in: pasteboard)
    }

    private static func isDragResizeEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return true
        default:
            return false
        }
    }

    private static func shouldDeferSurfaceResizeForActiveDrag(in window: NSWindow?) -> Bool {
        // The drag pasteboard can retain tab-transfer UTIs briefly after a split command
        // or other layout churn. Only defer terminal resizes while an actual drag event
        // is in flight; otherwise pre-existing panes can stay stuck at their old size.
        // Interactive geometry resize already has an explicit fast path for sidebar and
        // split-divider drags. Do not let stale drag-pasteboard state suppress those updates.
        if TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window) {
            return false
        }
        guard hasTabDragPasteboardTypes() else { return false }
        return isDragResizeEvent(NSApp.currentEvent?.type)
    }

    private func activeSurfaceResizeDeferralReason() -> String? {
        if isWindowLiveResizeActive { return nil }
        return Self.shouldDeferSurfaceResizeForActiveDrag(in: window) ? "tabDrag" : nil
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
        size: CGSize? = nil, bypassLiveResizeCoalescing: Bool = false, caller: StaticString = #function
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
            coalescePixelOnlyResize: TerminalSurfaceResizeCoalescingPolicy(
                windowLiveResizeActive: isWindowLiveResizeActive,
                interactiveGeometryResizeActive: TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window),
                bypass: bypassLiveResizeCoalescing,
                surfaceKind: terminalSurface.ioMode == .exec ? .processOwned : .manualIO
            ).shouldCoalescePixelOnlyResize,
            // Don't pin the surface to the tmux-assigned grid mid-drag: the pin
            // would hold it at the pre-drag (larger) size and paint past the
            // shrinking pane. Re-pins at rest when the interactive flag clears.
            suppressAssignedGridPin: isWindowLiveResizeActive
                || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window),
            caller: caller
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
    private func ensureSurfaceReadyForInput(reassertInputFocus: Bool = true) -> ghostty_surface_t? {
        if let surface = surface {
            if reassertInputFocus { _ = reassertTerminalFocusForInputIfFirstResponder() }
            return surface
        }
        guard window != nil else { return nil }
        terminalSurface?.attachToViewForInputDemand(self)
        updateSurfaceSize(size: bounds.size)
        applySurfaceColorScheme(force: true)
        if reassertInputFocus { _ = reassertTerminalFocusForInputIfFirstResponder() }
        return surface
    }
    private func reassertTerminalFocusForInputIfFirstResponder(forceNative: Bool = false) -> Bool {
        guard let terminalSurface, window?.firstResponder === self, !suppressingReparentFocus,
              isVisibleInUI, hasUsableFocusGeometry, !isHiddenOrHasHiddenAncestor,
              AppDelegate.shared?.allowsTerminalKeyboardFocus(workspaceId: terminalSurface.tabId, panelId: terminalSurface.id, in: window) != false else { return false }
        terminalSurface.setFocus(true); if forceNative, let surface { terminalSurface.recordExternalFocusState(true); ghostty_surface_set_focus(surface, true) }
        return true
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
        let inputSurface = terminalSurface
        let cancelledDeferredAdmission = inputSurface?.didReceiveExplicitInput() == true
        guard ensureSurfaceReadyForInput() != nil else {
            if cancelledDeferredAdmission || inputSurface?.canCreateRuntimeSurface == true,
               let inputSurface {
                guard queuePasteAfterSurfaceReady(for: inputSurface) else {
                    requestInputRecoveryAfterSurfaceMiss(reason: reason)
                    return false
                }
            }
            requestInputRecoveryAfterSurfaceMiss(reason: reason)
            return false
        }
        return true
    }
    func performBindingAction(_ action: String) -> Bool {
        if deferRuntimeInputDuringClipboardRead(
            estimatedBytes: action.utf8.count,
            replay: { [weak self] in
                _ = self?.performBindingAction(action)
            }
        ) {
            return true
        }
        return performBindingActionImmediately(action)
    }

    private func performBindingActionImmediately(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return withPotentialClipboardPasteIntent {
            action.withCString { cString in
                ghostty_surface_binding_action(
                    surface,
                    cString,
                    UInt(strlen(cString))
                )
            }
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

    func cancelKeyboardCopyMode() {
        guard keyboardCopyModeActive else { return }
        if let surface {
            _ = GhosttyRuntimeCInterop.clearSelection(surface)
        }
        setKeyboardCopyModeActive(false)
    }

    private func setKeyboardCopyModeActive(_ active: Bool) {
        keyboardCopyModeInputState.reset()
        keyboardCopyModeSelectionKind = nil
        keyboardCopyModeActive = active
        setKeyboardCopyModeRenderedFrameTrackingActive(active)
        if active, let surface {
            if !initializeKeyboardCopyModeCursor(surface: surface) {
                keyboardCopyModeCursor = nil
                keyboardCopyModeActive = false
                setKeyboardCopyModeRenderedFrameTrackingActive(false)
            }
            syncKeyboardCopyModeCursorOverlay(surface: surface)
        } else {
            if let surface {
                var column: UInt16 = 0
                var row: UInt16 = 0
                var widthCells: UInt16 = 0
                _ = ghostty_surface_keyboard_copy_cursor_set(
                    surface,
                    false,
                    &column,
                    &row,
                    &widthCells
                )
            }
            keyboardCopyModeCursor = nil
            syncKeyboardCopyModeCursorOverlay()
        }
        terminalSurface?.setKeyboardCopyModeActive(keyboardCopyModeActive)
    }

    private func setKeyboardCopyModeRenderedFrameTrackingActive(_ active: Bool) {
        if active {
            if keyboardCopyModeRenderedFrameDemandRelease == nil {
                let retention = keyboardCopyModeRenderedFrameDemand.retain()
                keyboardCopyModeRenderedFrameDemandRelease = {
                    retention.release()
                }
            }
            return
        }

        keyboardCopyModeRenderedFrameDemandRelease?()
        keyboardCopyModeRenderedFrameDemandRelease = nil
    }

    private func initializeKeyboardCopyModeCursor(surface: ghostty_surface_t) -> Bool {
        var column: UInt16 = 0
        var row: UInt16 = 0
        var widthCells: UInt16 = 0
        guard ghostty_surface_keyboard_copy_cursor_set(
            surface,
            true,
            &column,
            &row,
            &widthCells
        ) else { return false }

        keyboardCopyModeCursor = TerminalKeyboardCopyModeCursor(
            row: Int(row),
            column: Int(column)
        )
        return true
    }

    func runtimeSurfaceDidBecomeReady() {
        guard keyboardCopyModeActive, let surface else { return }
        guard initializeKeyboardCopyModeCursor(surface: surface) else {
            setKeyboardCopyModeActive(false)
            return
        }
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    @discardableResult
    private func performBindingAction(_ action: String, repeatCount: Int) -> Bool {
        var performed = true
        for _ in 0 ..< terminalKeyboardCopyModeClampCount(repeatCount) { performed = performBindingAction(action) && performed }
        return performed
    }

    private func keyboardCopyModeGridMetrics(surface: ghostty_surface_t) -> KeyboardCopyModeGridMetrics? {
        var native = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &native),
              native.cell_width.isFinite,
              native.cell_width > 0,
              native.cell_height.isFinite,
              native.cell_height > 0,
              native.padding_left.isFinite,
              native.padding_top.isFinite else { return nil }

        return KeyboardCopyModeGridMetrics(
            cellWidth: CGFloat(native.cell_width),
            cellHeight: CGFloat(native.cell_height),
            xInset: CGFloat(native.padding_left),
            yInset: CGFloat(native.padding_top),
            viewHeight: bounds.height
        )
    }

    private func keyboardCopyModeTrackedCursor(
        surface: ghostty_surface_t
    ) -> KeyboardCopyModeResolvedCell? {
        var snapshot = ghostty_keyboard_copy_cursor_s()
        guard ghostty_surface_keyboard_copy_cursor_snapshot(
            surface,
            &snapshot
        ) else { return nil }

        return KeyboardCopyModeResolvedCell(
            cursor: TerminalKeyboardCopyModeCursor(
                row: Int(snapshot.row),
                column: Int(snapshot.column)
            ),
            widthCells: max(Int(snapshot.width_cells), 1),
            color: Self.keyboardCopyModeCursorColor(
                red: snapshot.color_red,
                green: snapshot.color_green,
                blue: snapshot.color_blue
            )
        )
    }

    static func keyboardCopyModeCursorColor(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    private func syncKeyboardCopyModeSelectionKind(surface: ghostty_surface_t) {
        let nativeKind = ghostty_surface_keyboard_copy_selection_kind(surface)
        if nativeKind == GHOSTTY_KEYBOARD_COPY_SELECTION_CHARACTER {
            keyboardCopyModeSelectionKind = .character
        } else if nativeKind == GHOSTTY_KEYBOARD_COPY_SELECTION_LINE {
            keyboardCopyModeSelectionKind = .line
        } else {
            keyboardCopyModeSelectionKind = nil
        }
    }

    private func syncKeyboardCopyModeCursorOverlay(surface explicitSurface: ghostty_surface_t? = nil) {
        guard keyboardCopyModeActive,
              let surface = explicitSurface ?? self.surface,
              let resolved = keyboardCopyModeTrackedCursor(surface: surface) else {
            keyboardCopyModeCursorOverlayView.isHidden = true
            return
        }

        keyboardCopyModeCursor = resolved.cursor
        syncKeyboardCopyModeSelectionKind(surface: surface)
        guard !keyboardCopyModeVisualActive,
              let metrics = keyboardCopyModeGridMetrics(surface: surface) else {
            keyboardCopyModeCursorOverlayView.isHidden = true
            return
        }
        keyboardCopyModeCursorOverlayView.frame = metrics.appKitRect(for: resolved)
        keyboardCopyModeCursorOverlayView.layer?.borderColor = resolved.color.cgColor
        keyboardCopyModeCursorOverlayView.isHidden = false
    }

    private func moveKeyboardCopyModeCursor(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard let nativeCount = UInt16(
            exactly: terminalKeyboardCopyModeClampCount(count)
        ) else {
            return
        }

        var resolvedColumn: UInt16 = 0
        var resolvedRow: UInt16 = 0
        var widthCells: UInt16 = 0
        guard ghostty_surface_keyboard_selection_move(
            surface,
            nativeKeyboardCopyModeMove(direction),
            nativeCount,
            false,
            false,
            &resolvedColumn,
            &resolvedRow,
            &widthCells
        ) else { return }

        keyboardCopyModeCursor = TerminalKeyboardCopyModeCursor(
            row: Int(resolvedRow),
            column: Int(resolvedColumn)
        )
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func nativeKeyboardCopyModeMove(
        _ direction: TerminalKeyboardCopyModeSelectionMove
    ) -> ghostty_keyboard_selection_move_e {
        switch direction {
        case .left:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_LEFT
        case .right:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_RIGHT
        case .up:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_UP
        case .down:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_DOWN
        case .pageUp:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_UP
        case .pageDown:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_PAGE_DOWN
        case .home:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_HOME
        case .end:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_END
        case .beginningOfLine:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_BEGINNING_OF_LINE
        case .endOfLine:
            GHOSTTY_KEYBOARD_SELECTION_MOVE_END_OF_LINE
        }
    }

    @discardableResult
    private func performKeyboardCopyModeViewportScroll(
        surface: ghostty_surface_t,
        action: ghostty_keyboard_copy_scroll_e,
        amount: Int
    ) -> Bool {
        guard let nativeAmount = Int32(exactly: amount) else { return false }
        var column: UInt16 = 0
        var row: UInt16 = 0
        var widthCells: UInt16 = 0
        guard ghostty_surface_keyboard_copy_scroll(
            surface,
            action,
            nativeAmount,
            &column,
            &row,
            &widthCells
        ) else { return false }

        keyboardCopyModeCursor = TerminalKeyboardCopyModeCursor(
            row: Int(row),
            column: Int(column)
        )
        syncKeyboardCopyModeCursorOverlay(surface: surface)
        return true
    }

    private func reconcileKeyboardCopyModeViewport(surface: ghostty_surface_t) {
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func startKeyboardCopyModeSelection(
        surface: ghostty_surface_t,
        linewise: Bool,
        lineCount: Int
    ) -> Bool {
        guard let nativeLineCount = UInt16(
            exactly: terminalKeyboardCopyModeClampCount(lineCount)
        ) else { return false }

        var column: UInt16 = 0
        var row: UInt16 = 0
        var widthCells: UInt16 = 0
        guard ghostty_surface_keyboard_copy_selection_start(
            surface,
            linewise,
            nativeLineCount,
            &column,
            &row,
            &widthCells
        ) else { return false }

        keyboardCopyModeCursor = TerminalKeyboardCopyModeCursor(
            row: Int(row),
            column: Int(column)
        )
        return true
    }

    private func startKeyboardCopyModeVisualSelection(surface: ghostty_surface_t) -> Bool {
        guard startKeyboardCopyModeSelection(
            surface: surface,
            linewise: false,
            lineCount: 1
        ) else { return false }
        keyboardCopyModeSelectionKind = .character
        syncKeyboardCopyModeCursorOverlay(surface: surface)
        return true
    }

    private func adjustKeyboardCopyModeVisualSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard keyboardCopyModeSelectionKind == .character else { return }
        moveKeyboardCopyModeSelectionEndpoint(
            direction,
            count: count,
            linewise: false,
            surface: surface
        )
    }

    private func clearKeyboardCopyModeVisualSelection(surface: ghostty_surface_t) {
        keyboardCopyModeSelectionKind = nil
        _ = GhosttyRuntimeCInterop.clearSelection(surface)
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func copyCurrentGhosttySelectionToClipboard(surface: ghostty_surface_t) -> Bool {
        let copyAction = "copy_to_clipboard"
        let formattedRepresentations = GhosttyApp.terminalPasteboard
            .captureNextStandardClipboardRepresentations {
                performBindingActionImmediately(copyAction)
            }
        if let formattedRepresentations {
            GhosttyApp.terminalPasteboard.writeRepresentations(
                formattedRepresentations,
                to: GHOSTTY_CLIPBOARD_STANDARD
            )
            return true
        }

        guard let selectedText = readSelectionSnapshot(surface: surface)?.string, !selectedText.isEmpty else {
            return false
        }

        GhosttyApp.terminalPasteboard.writeString(selectedText, to: GHOSTTY_CLIPBOARD_STANDARD)
        return true
    }

    private func copyKeyboardCopyModeSelectionToClipboard(surface: ghostty_surface_t) -> Bool {
        let maximumBytes = UInt(
            TerminalClipboardRepresentationDecoder.defaultMaximumRichTextBytes
        )
        return ghostty_surface_copy_selection_to_clipboard_bounded(
            surface,
            maximumBytes
        )
    }

    private func hasCopyableTerminalSelection(surface: ghostty_surface_t) -> Bool {
        ghostty_surface_has_selection(surface)
    }

    /// Keep the standard Copy shortcut a native no-op when AppKit disables
    /// Copy. Replaying this menu miss into Ghostty lets the failed Copy binding
    /// enter its terminal-input path, which moves scrollback to the bottom when
    /// `scroll-to-bottom=keystroke` is enabled even if the terminal program
    /// does not visibly echo that input.
    func consumeUnavailableCopyMenuAction(_ event: NSEvent) -> Bool {
        let normalizedFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard event.type == .keyDown,
              normalizedFlags == [.command],
              KeyboardLayout.normalizedCharacters(for: event) == "c" else {
            return false
        }
        guard let surface = ensureSurfaceReadyForInput(),
              !hasCopyableTerminalSelection(surface: surface) else {
            return false
        }

        return ghosttyConsumeMenuAction(
            "copy_to_clipboard",
            for: event,
            surface: surface
        )
    }

    private func copyCurrentViewportLinesToClipboard(
        surface: ghostty_surface_t,
        lineCount: Int
    ) -> Bool {
        guard startKeyboardCopyModeSelection(
            surface: surface,
            linewise: true,
            lineCount: lineCount
        ) else { return false }
        return copyKeyboardCopyModeSelectionToClipboard(surface: surface)
    }

    private func startKeyboardCopyModeLineSelection(surface: ghostty_surface_t, lineCount: Int) {
        guard startKeyboardCopyModeSelection(
            surface: surface,
            linewise: true,
            lineCount: lineCount
        ) else { return }
        keyboardCopyModeSelectionKind = .line
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func adjustKeyboardCopyModeVisualLineSelection(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        surface: ghostty_surface_t
    ) {
        guard keyboardCopyModeSelectionKind == .line else { return }
        moveKeyboardCopyModeSelectionEndpoint(
            direction,
            count: count,
            linewise: true,
            surface: surface
        )
    }

    private func moveKeyboardCopyModeSelectionEndpoint(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        linewise: Bool,
        surface: ghostty_surface_t
    ) {
        guard let nativeCount = UInt16(
            exactly: terminalKeyboardCopyModeClampCount(count)
        ) else {
            return
        }

        var resolvedColumn: UInt16 = 0
        var resolvedRow: UInt16 = 0
        var widthCells: UInt16 = 0
        guard ghostty_surface_keyboard_selection_move(
            surface,
            nativeKeyboardCopyModeMove(direction),
            nativeCount,
            true,
            linewise,
            &resolvedColumn,
            &resolvedRow,
            &widthCells
        ) else { return }

        keyboardCopyModeCursor = TerminalKeyboardCopyModeCursor(
            row: Int(resolvedRow),
            column: Int(resolvedColumn)
        )
        syncKeyboardCopyModeCursorOverlay(surface: surface)
    }

    private func handleKeyboardCopyModeIfNeeded(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        guard keyboardCopyModeActive else { return false }
        reconcileKeyboardCopyModeViewport(surface: surface)

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
            _ = startKeyboardCopyModeVisualSelection(surface: surface)
        case .startLineSelection:
            startKeyboardCopyModeLineSelection(surface: surface, lineCount: count)
        case .clearSelection:
            clearKeyboardCopyModeVisualSelection(surface: surface)
        case .copyAndExit:
            if copyKeyboardCopyModeSelectionToClipboard(surface: surface) { _ = GhosttyRuntimeCInterop.clearSelection(surface); setKeyboardCopyModeActive(false) }
        case .copyLineAndExit:
            if copyCurrentViewportLinesToClipboard(
                surface: surface,
                lineCount: count
            ) {
                _ = GhosttyRuntimeCInterop.clearSelection(surface)
                setKeyboardCopyModeActive(false)
            }
        case let .scrollLines(delta):
            let lineDelta = delta * terminalKeyboardCopyModeClampCount(count)
            _ = performKeyboardCopyModeViewportScroll(
                surface: surface,
                action: GHOSTTY_KEYBOARD_COPY_SCROLL_LINES,
                amount: lineDelta
            )
        case let .scrollPage(delta):
            let pageDelta = delta * terminalKeyboardCopyModeClampCount(count)
            _ = performKeyboardCopyModeViewportScroll(
                surface: surface,
                action: GHOSTTY_KEYBOARD_COPY_SCROLL_PAGES,
                amount: pageDelta
            )
        case let .scrollHalfPage(delta):
            let halfPageDelta = delta * terminalKeyboardCopyModeClampCount(count)
            _ = performKeyboardCopyModeViewportScroll(
                surface: surface,
                action: GHOSTTY_KEYBOARD_COPY_SCROLL_HALF_PAGES,
                amount: halfPageDelta
            )
        case .scrollToTop:
            moveKeyboardCopyModeCursor(.home, count: 1, surface: surface)
        case .scrollToBottom:
            moveKeyboardCopyModeCursor(.end, count: 1, surface: surface)
        case let .jumpToPrompt(delta):
            _ = performKeyboardCopyModeViewportScroll(
                surface: surface,
                action: GHOSTTY_KEYBOARD_COPY_SCROLL_PROMPTS,
                amount: delta * terminalKeyboardCopyModeClampCount(count)
            )
        case .startSearch:
            _ = performBindingAction("start_search")
        case .searchNext:
            _ = TerminalSearchNavigation.next.perform { performBindingAction($0, repeatCount: count) }
        case .searchPrevious:
            _ = TerminalSearchNavigation.previous.perform { performBindingAction($0, repeatCount: count) }
        case let .adjustSelection(direction):
            if keyboardCopyModeVisualLineActive {
                adjustKeyboardCopyModeVisualLineSelection(direction, count: count, surface: surface)
            } else if keyboardCopyModeSelectionKind == .character {
                adjustKeyboardCopyModeVisualSelection(direction, count: count, surface: surface)
            } else {
                moveKeyboardCopyModeCursor(direction, count: count, surface: surface)
            }
        }
        return true
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        guard let surface else {
            _ = performBindingActionImmediately("copy_to_clipboard")
            return
        }
        if keyboardCopyModeActive {
            _ = copyKeyboardCopyModeSelectionToClipboard(surface: surface)
        } else {
            _ = copyCurrentGhosttySelectionToClipboard(surface: surface)
        }
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

    func readSelectionSnapshot(surface explicitSurface: ghostty_surface_t? = nil) -> SelectionSnapshot? {
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
            manualNamedKeyConsumedKeyUps.removeAll()
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
        if result, shouldApplySurfaceFocus, let surface = ensureSurfaceReadyForInput(reassertInputFocus: false) {
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
                var userInfo: [AnyHashable: Any] = [
                    GhosttyNotificationKey.tabId: terminalSurface.tabId,
                    GhosttyNotificationKey.surfaceId: terminalSurface.id,
                ]
                if let firstResponderFocusTransactionId {
                    userInfo[GhosttyNotificationKey.focusTransactionId] = firstResponderFocusTransactionId
                }
                NotificationCenter.default.post(
                    name: .ghosttyDidBecomeFirstResponderSurface,
                    object: nil,
                    userInfo: userInfo
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
            manualNamedKeyConsumedKeyUps.removeAll()
            desiredFocus = false
            deferReleaseAllGhosttyMouseButtons(
                reason: "resignFirstResponder"
            )
            cancelKeyboardCopyMode()
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
    struct SelectionSnapshot {
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
        let bindingFlags = ghosttyBindingFlags(for: event, surface: surface)

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

    private func ghosttyBindingFlags(
        for event: NSEvent,
        surface: ghostty_surface_t
    ) -> ghostty_binding_flags_e? {
        var flags = ghostty_binding_flags_e(0)
        let isBinding = withGhosttyBindingKeyEvent(for: event, surface: surface) { keyEvent in
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        return isBinding ? flags : nil
    }

    private func ghosttyConsumeMenuAction(
        _ action: String,
        for event: NSEvent,
        surface: ghostty_surface_t
    ) -> Bool {
        withGhosttyBindingKeyEvent(for: event, surface: surface) { keyEvent in
            action.withCString { actionPointer in
                withPotentialClipboardPasteIntent {
                    ghostty_surface_key_consume_if_menu_action(
                        surface,
                        keyEvent,
                        actionPointer,
                        UInt(action.utf8.count)
                    )
                }
            }
        }
    }

    private func withGhosttyBindingKeyEvent<Result>(
        for event: NSEvent,
        surface: ghostty_surface_t,
        _ body: (ghostty_input_key_s) -> Result
    ) -> Result {
        var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
        let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
        return text.withCString { pointer in
            keyEvent.text = pointer
            return body(keyEvent)
        }
    }

    override func keyDown(with event: NSEvent) {
        if routeInputDuringClipboardRead(event) { return }
        let cancelledDeferredAdmission = terminalSurface?.didReceiveExplicitInput() == true
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        let phaseTotalStart = ProcessInfo.processInfo.systemUptime
        var ensureSurfaceMs: Double = 0
        var rightSidebarShortcutMs: Double = 0
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
                    ("rightSidebarShortcutMs", rightSidebarShortcutMs),
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
            if cancelledDeferredAdmission ||
                pendingExplicitKeyDownKeyCodes.isEmpty == false ||
                terminalSurface?.canCreateRuntimeSurface == true {
                queueExplicitKeyDownForInputDemand(event)
                requestInputRecoveryAfterSurfaceMiss(reason: "keyDown.missingSurface.afterRestoreCancel")
                return
            }
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
        let appDelegate = AppDelegate.shared
#if DEBUG
        let rightSidebarShortcutStart = ProcessInfo.processInfo.systemUptime
#endif
        let rightSidebarMode = appDelegate?.rightSidebarModeShortcut(for: event)
#if DEBUG
        rightSidebarShortcutMs = (ProcessInfo.processInfo.systemUptime - rightSidebarShortcutStart) * 1000.0
#endif
        if let appDelegate,
           let mode = rightSidebarMode,
           let window,
           appDelegate.shouldRouteRightSidebarModeShortcut(in: window) {
            _ = appDelegate.focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: window)
            return
        }
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if !cmuxFindEventIsPlainEscape(event) { endFindEscapeSuppression() }
        if shouldConsumeSuppressedFindEscape(event) { return }
        if cmuxFindEventIsPlainEscape(event), !hasMarkedText(), let terminalSurface, terminalSurface.searchState != nil {
            terminalSurface.closeSearchFromExplicitInput()
            beginFindEscapeSuppression(); return
        }
#if DEBUG
        let keyboardCopyModeStart = ProcessInfo.processInfo.systemUptime
#endif
        if handleKeyboardCopyModeIfNeeded(event, surface: surface) {
#if DEBUG
            keyboardCopyModeMs = (ProcessInfo.processInfo.systemUptime - keyboardCopyModeStart) * 1000.0
#endif
            terminalSurface?.didAcceptExplicitInput()
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
        if flags.contains(.control) && !flags.contains(.command) && !flags.contains(.option) && !hasMarkedText() {
            _ = reassertTerminalFocusForInputIfFirstResponder(forceNative: true)
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
                handled = sendGhosttyKey(surface, keyEvent)
                #endif
            } else {
                #if DEBUG
                let sendTimingStart = CmuxTypingTiming.start()
                let ghosttySendStart = ProcessInfo.processInfo.systemUptime
                #endif
                handled = text.withCString { ptr in
                    keyEvent.text = ptr
                    return sendGhosttyKey(surface, keyEvent)
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
                    _ = sendGhosttyKey(surface, keyEvent)
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
                _ = sendGhosttyKey(surface, keyEvent)
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
                    _ = sendGhosttyKey(surface, keyEvent)
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
                _ = sendGhosttyKey(surface, keyEvent)
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
        if !manualNamedKeyConsumedKeyUps.isEmpty,
           keyEvent.action == GHOSTTY_ACTION_RELEASE,
           let keyCode = UInt16(exactly: keyEvent.keycode),
           manualNamedKeyConsumedKeyUps.remove(keyCode) != nil {
            return true
        }
        if let keyName = terminalSurface?.manualInputKeyName(for: keyEvent) {
            var bindingFlags = ghostty_binding_flags_e(0)
            if !ghostty_surface_key_is_binding(surface, keyEvent, &bindingFlags) {
                if terminalSurface?.enqueueManualInputNamedKey(keyName) == true {
                    if let keyCode = UInt16(exactly: keyEvent.keycode) {
                        manualNamedKeyConsumedKeyUps.insert(keyCode)
                    }
                    terminalSurface?.didAcceptExplicitInput()
                    return true
                }
            }
        }
        let handled = withPotentialClipboardPasteIntent {
            ghostty_surface_key(surface, keyEvent)
        }
        if handled, keyEvent.action != GHOSTTY_ACTION_RELEASE {
            terminalSurface?.didAcceptExplicitInput()
        }
        return handled
    }

    private func sendGhosttyMouseButton(
        _ surface: ghostty_surface_t,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        withPotentialClipboardPasteIntent {
            ghostty_surface_mouse_button(surface, state, button, mods)
        }
    }

    private func sendSyntheticGhosttyMouseRelease(
        _ surface: ghostty_surface_t,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) -> Bool {
        // A lifecycle cancellation must not commit a selection or invoke a
        // prompt/link action. Clear the selection before the release (so
        // copy-on-select has nothing to publish), then move the native pointer
        // outside the viewport (so prompt/link hit-testing cannot match).
        if button == GHOSTTY_MOUSE_LEFT {
            if ghostty_surface_has_selection(surface) {
                _ = ghostty_surface_clear_selection(surface)
            }
            ghostty_surface_mouse_pos(surface, -1, -1, mods)
        }
        return sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_RELEASE,
            button: button,
            mods: mods
        )
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
        if routeInputDuringClipboardRead(event) { return }
        if !replayingPendingInput,
           pendingExplicitKeyDownKeyCodes[event.keyCode] != nil {
            guard pendingInputReplayActions.count < Self.maximumPendingInputReplayActions else {
                return
            }
            pendingInputReplayActions.append(.keyUp(event))
            return
        }
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
        if routeInputDuringClipboardRead(event) { return }
        guard let surface = ensureSurfaceReadyForInput() else {
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

    private func ghosttyMouseSurfaceIdentity(
        for terminalSurface: TerminalSurface
    ) -> GhosttyMouseSessionLedger.SurfaceIdentity? {
        guard let nativeSurface = terminalSurface.surface else { return nil }
        return GhosttyMouseSessionLedger.SurfaceIdentity(
            surfaceID: terminalSurface.id,
            runtimeGeneration: terminalSurface.runtimeSurfaceGeneration,
            nativeAddress: UInt(bitPattern: nativeSurface)
        )
    }

    private var currentGhosttyMouseSurfaceIdentity:
        GhosttyMouseSessionLedger.SurfaceIdentity? {
        guard let terminalSurface else { return nil }
        return ghosttyMouseSurfaceIdentity(for: terminalSurface)
    }

    /// Moves the ledger to the currently attached native runtime. A runtime
    /// replacement clears old sessions before any event can reach the new
    /// pointer, so stale releases are never sent across generations.
    @discardableResult
    private func synchronizeGhosttyMouseSurfaceIdentity() -> Bool {
        let didChange = ghosttyMouseSessionLedger.transition(
            to: currentGhosttyMouseSurfaceIdentity
        )
        if didChange {
            cancelDeferredGhosttyMouseRepair()
            removeMouseUpEventMonitorIfUnused()
        }
        return didChange
    }

    @discardableResult
    private func rememberGhosttyMouseState(from event: NSEvent) -> RememberedGhosttyMouseState {
        synchronizeGhosttyMouseSurfaceIdentity()
        let localPoint = convert(event.locationInWindow, from: nil)
        let surfacePoint = NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
        let mods = mouseModsFromEvent(event)
        let state = RememberedGhosttyMouseState(
            localPoint: localPoint,
            surfacePoint: surfacePoint,
            mods: mods
        )
        if let surfaceIdentity = currentGhosttyMouseSurfaceIdentity {
            ghosttyMouseSessionLedger.rememberPointer(state, on: surfaceIdentity)
        }
        return state
    }

    /// Synchronously reconciles the ledger at an AppKit event boundary. Drag
    /// dispatch itself never calls this method, so a captured drag cannot be
    /// released from an unrelated physical-button snapshot.
    private func reconcileGhosttyMouseButtons(
        reason: String,
        forceButtons: Set<TrackedMouseButton> = []
    ) {
        guard let surface,
              let surfaceIdentity = currentGhosttyMouseSurfaceIdentity else {
            resetGhosttyMouseButtonTracking()
            return
        }
        guard ghosttyMouseSessionLedger.activeSurface == surfaceIdentity else {
            // The native pointer changed without a view attachment callback.
            // Invalidate rather than risking a release on the replacement.
            synchronizeGhosttyMouseSurfaceIdentity()
            return
        }
        guard !ghosttyMouseSessionLedger.activeButtons.isEmpty else { return }

        let physicalButtons = NSEvent.pressedMouseButtons
        let forcedSessions = Set(
            ghosttyMouseSessionLedger
                .sessions(on: surfaceIdentity)
                .filter { forceButtons.contains($0.button) }
        )
        performGhosttyMouseRepair(
            reason: reason,
            surface: surface,
            surfaceIdentity: surfaceIdentity,
            physicalButtons: physicalButtons,
            forcedSessions: forcedSessions,
            suppressSideEffects: false
        )
    }

    private func performGhosttyMouseRepair(
        reason: String,
        surface: ghostty_surface_t,
        surfaceIdentity: GhosttyMouseSessionLedger.SurfaceIdentity,
        physicalButtons: Int?,
        forcedSessions: Set<GhosttyMouseSessionLedger.Session>,
        suppressSideEffects: Bool
    ) {
        guard let terminalSurface,
              let validatedSurface = terminalSurface.liveSurfaceForGhosttyAccess(
                  reason: "mouseRepair.\(reason)"
              ),
              UInt(bitPattern: validatedSurface) == surfaceIdentity.nativeAddress,
              UInt(bitPattern: validatedSurface) == UInt(bitPattern: surface) else {
            // `surface` can be a stale wrapper even when its pointer bits have
            // not changed. The owning model's liveness seam quarantines that
            // case; clear our session/monitor mirror before returning.
            resetGhosttyMouseButtonTracking()
            return
        }
        guard currentGhosttyMouseSurfaceIdentity == surfaceIdentity,
              ghosttyMouseSessionLedger.activeSurface == surfaceIdentity else {
            synchronizeGhosttyMouseSurfaceIdentity()
            return
        }
        let sessions = ghosttyMouseSessionLedger.sessionsNeedingRepair(
            on: surfaceIdentity,
            physicalButtons: physicalButtons,
            forcedSessions: forcedSessions
        )
        guard !sessions.isEmpty else { return }

        let pointer = ghosttyMouseSessionLedger.pointerState
        if let surfacePoint = pointer?.surfacePoint {
            ghostty_surface_mouse_pos(
                validatedSurface,
                surfacePoint.x,
                surfacePoint.y,
                pointer?.mods ?? GHOSTTY_MODS_NONE
            )
        }

#if DEBUG
        let buttonList = sessions.map { $0.button.rawValue }.joined(separator: ",")
        cmuxDebugLog(
            "terminal.mouseRepair surface=\(terminalSurface.id.uuidString.prefix(5)) " +
            "reason=\(reason) buttons=\(buttonList) physicalMask=\(physicalButtons.map(String.init) ?? "none")"
        )
#endif

        for session in sessions {
            guard ghosttyMouseSessionLedger.session(
                for: session.button,
                on: surfaceIdentity
            ) == session else { continue }
            if suppressSideEffects {
                _ = sendSyntheticGhosttyMouseRelease(
                    validatedSurface,
                    button: session.button.ghosttyButton,
                    mods: pointer?.mods ?? GHOSTTY_MODS_NONE
                )
            } else {
                _ = sendGhosttyMouseButton(
                    validatedSurface,
                    state: GHOSTTY_MOUSE_RELEASE,
                    button: session.button.ghosttyButton,
                    mods: pointer?.mods ?? GHOSTTY_MODS_NONE
                )
            }
            _ = finishGhosttyMouseSession(session)
        }
    }

    func reconcileGhosttyMouseButtons(reason: String) {
        reconcileGhosttyMouseButtons(reason: reason, forceButtons: [])
    }

    private func cancelDeferredGhosttyMouseRepair() {
        deferredGhosttyMouseRepairTask?.cancel()
        deferredGhosttyMouseRepairTask = nil
    }

    /// Defers lifecycle cleanup until the portal/layout callback has returned.
    /// The immutable session tokens and surface identity make this an explicit
    /// handoff, not a timing guard: a newer press or runtime cannot be touched
    /// when the task runs.
    private func deferGhosttyMouseButtonRepair(
        reason: String,
        forceButtons: Set<TrackedMouseButton> = [],
        forceAll: Bool = false
    ) {
        guard currentGhosttyMouseSurfaceIdentity != nil,
              let surfaceIdentity = currentGhosttyMouseSurfaceIdentity,
              ghosttyMouseSessionLedger.activeSurface == surfaceIdentity else {
            synchronizeGhosttyMouseSurfaceIdentity()
            return
        }
        let sessions = Set(ghosttyMouseSessionLedger.sessions(on: surfaceIdentity))
        guard !sessions.isEmpty else { return }
        let forcedSessions = forceAll
            ? sessions
            : Set(sessions.filter { forceButtons.contains($0.button) })

        cancelDeferredGhosttyMouseRepair()
        deferredGhosttyMouseRepairTask = Task { @MainActor [weak self, surfaceIdentity, forcedSessions, reason, forceAll] in
            // Yield once so Ghostty releases never run inside SwiftUI/AppKit
            // hierarchy reconciliation. This is a cancellable, identity-bound
            // lifecycle handoff rather than a poll or retry.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            guard let surface = self.surface else {
                self.resetGhosttyMouseButtonTracking()
                return
            }
            guard self.currentGhosttyMouseSurfaceIdentity == surfaceIdentity,
                  self.ghosttyMouseSessionLedger.activeSurface == surfaceIdentity else {
                self.synchronizeGhosttyMouseSurfaceIdentity()
                return
            }
            self.performGhosttyMouseRepair(
                reason: reason,
                surface: surface,
                surfaceIdentity: surfaceIdentity,
                physicalButtons: forceAll ? nil : NSEvent.pressedMouseButtons,
                forcedSessions: forcedSessions,
                suppressSideEffects: true
            )
        }
    }

    private func releaseAllGhosttyMouseButtonsSynchronously(reason: String) {
        guard let surface,
              let surfaceIdentity = currentGhosttyMouseSurfaceIdentity else {
            resetGhosttyMouseButtonTracking()
            return
        }
        guard ghosttyMouseSessionLedger.activeSurface == surfaceIdentity else {
            synchronizeGhosttyMouseSurfaceIdentity()
            return
        }
        let sessions = Set(ghosttyMouseSessionLedger.sessions(on: surfaceIdentity))
        guard !sessions.isEmpty else { return }
        cancelDeferredGhosttyMouseRepair()
        performGhosttyMouseRepair(
            reason: reason,
            surface: surface,
            surfaceIdentity: surfaceIdentity,
            physicalButtons: nil,
            forcedSessions: sessions,
            suppressSideEffects: true
        )
        resetGhosttyMouseButtonTracking()
    }

    fileprivate func deferReleaseAllGhosttyMouseButtons(reason: String) {
        guard currentGhosttyMouseSurfaceIdentity != nil,
              !ghosttyMouseSessionLedger.activeButtons.isEmpty else {
            resetGhosttyMouseButtonTracking()
            return
        }
        deferGhosttyMouseButtonRepair(reason: reason, forceAll: true)
    }

    fileprivate func deferReconcileGhosttyMouseButtons(reason: String) {
        deferGhosttyMouseButtonRepair(reason: reason, forceAll: false)
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

    /// Applies terminal focus intent for pointer-downs that land outside the
    /// capped terminal content but remain inside its pane.
    func focusFromPointerDown() {
        if let terminalSurface {
            activateContainerFocusFromPointerDown()
            terminalSurface.hostedView.clearReparentFocusSuppressionForPointerFocus()
        }
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        terminalSurface?.didAcceptExplicitInput()
    }

    override func mouseDown(with event: NSEvent) {
        if routeInputDuringClipboardRead(event) { return }
        reconcileGhosttyMouseButtons(
            reason: "mouseDown.preflight",
            forceButtons: Set([.left])
        )
        let shouldForwardTerminalActivation = terminalPointerShouldForwardActivation()
        // Treat pointer-down as explicit focus intent before forwarding any terminal activation.
        focusFromPointerDown()
        guard shouldForwardTerminalActivation else { return }
        guard let surface = surface else { return }
        // Focus activation can synchronously reparent or resize the portal.
        // Convert the event after that transaction so the press lands in the
        // current terminal geometry.
        let mouseState = rememberGhosttyMouseState(from: event)
        #if DEBUG
        let debugPoint = mouseState.localPoint
        cmuxDebugLog("terminal.mouseDown surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))] clickCount=\(event.clickCount) point=(\(String(format: "%.0f", debugPoint.x)),\(String(format: "%.0f", debugPoint.y)))")
        #endif
        let eventPoint = mouseState.localPoint
        trackMousePointIfUsable(eventPoint)
        // Only update mouse position on the first click to prevent unwanted cursor
        // movement during double-click selection (issue #1698)
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, mouseState.surfacePoint.x, mouseState.surfacePoint.y, mouseState.mods)
        }
        _ = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mouseState.mods
        )
        _ = markGhosttyMouseButtonPressed(.left)
    }

    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        cmuxDebugLog("terminal.mouseUp surface=\(terminalSurface?.id.uuidString.prefix(5) ?? "nil") mods=[\(debugModifierString(event.modifierFlags))]")
        #endif
        completePendingLeftMouseRelease(with: event)
    }

    @discardableResult
    func forwardPendingLeftMouseDrag(with event: NSEvent) -> Bool {
        if routeInputDuringClipboardRead(event) { return true }
        synchronizeGhosttyMouseSurfaceIdentity()
        guard let surface,
              ghosttyMouseSessionLedger.hasSession(
                  for: .left,
                  on: currentGhosttyMouseSurfaceIdentity
              ) else { return false }
        let mouseState = rememberGhosttyMouseState(from: event)
        let eventPoint = mouseState.localPoint
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(surface, mouseState.surfacePoint.x, mouseState.surfacePoint.y, mouseState.mods)
        return true
    }

    @discardableResult
    func completePendingLeftMouseRelease(with event: NSEvent) -> Bool {
        if routeInputDuringClipboardRead(event) { return true }
        synchronizeGhosttyMouseSurfaceIdentity()
        guard let surfaceIdentity = currentGhosttyMouseSurfaceIdentity,
              let pendingSession = ghosttyMouseSessionLedger.session(
                  for: .left,
                  on: surfaceIdentity
              ) else { return false }
        let mouseState = rememberGhosttyMouseState(from: event)
        guard let surface,
              currentGhosttyMouseSurfaceIdentity == surfaceIdentity else {
            // A portal can detach the runtime between the press and release.
            // Clear our mirror even when there is no surface left to receive it.
            resetGhosttyMouseButtonTracking()
            return false
        }
        let point = mouseState.localPoint
        _ = dispatchCommandClickRelease(
            surface: surface,
            at: point,
            modifierFlags: event.modifierFlags,
            mouseMods: mouseState.mods
        )
        _ = finishGhosttyMouseSession(pendingSession)
        return true
    }

    private func beginCommandClickReleaseRouting() {
        commandClickReleaseRoutingActive = true
        commandClickReleaseRuntimeOutcome = nil
    }

    /// Records a URL action only while its originating mouse release is active.
    /// Other Ghostty URL actions must not affect a later path fallback.
    fileprivate func recordCommandClickReleaseRuntimeOutcome(
        _ outcome: TerminalCommandClickReleaseRouter.RuntimeOutcome
    ) {
        guard commandClickReleaseRoutingActive else { return }
        commandClickReleaseRuntimeOutcome = outcome
    }

    private func finishCommandClickReleaseRouting(
        ghosttyConsumed: Bool
    ) -> TerminalCommandClickReleaseRouter.RuntimeOutcome {
        defer {
            commandClickReleaseRoutingActive = false
            commandClickReleaseRuntimeOutcome = nil
        }
        guard commandClickReleaseRoutingActive else {
            return ghosttyConsumed ? .consumed : .unhandled
        }
        return commandClickReleaseRuntimeOutcome ?? (ghosttyConsumed ? .consumed : .unhandled)
    }

    @discardableResult
    private func dispatchCommandClickRelease(
        surface: ghostty_surface_t,
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags,
        mouseMods: ghostty_input_mods_e
    ) -> (
        consumed: Bool,
        runtimeOutcome: TerminalCommandClickReleaseRouter.RuntimeOutcome,
        resolution: WordPathResolution?
    ) {
        beginCommandClickReleaseRouting()
        let consumed = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mouseMods
        )
        let runtimeOutcome = finishCommandClickReleaseRouting(ghosttyConsumed: consumed)
        let resolution = handleCommandClickRelease(
            at: point,
            modifierFlags: modifierFlags,
            runtimeOutcome: runtimeOutcome
        )
        return (consumed, runtimeOutcome, resolution)
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
              workspace.canResolveTerminalPathsAgainstLocalFilesystem(
                  surfaceID: termSurface.id
              ) else { return nil }

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

    private func wordPathSnapshotTerminalPanel(
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> TerminalPanel? {
        guard workspace.canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: terminalSurface.id
        ) else { return nil }
        return workspace.controlTerminalPanel(for: terminalSurface.id)
    }

#if DEBUG
    func debugWordPathSnapshotTerminalPanelID() -> UUID? {
        guard let terminalSurface,
              let workspace = terminalSurface.owningWorkspace() else {
            return nil
        }
        return wordPathSnapshotTerminalPanel(
            workspace: workspace,
            terminalSurface: terminalSurface
        )?.id
    }
#endif

    private func resolveVisibleWordPathFromViewportOffset(
        _ viewportOffsetStart: Int,
        cwd: String,
        workspace: Workspace,
        terminalSurface: TerminalSurface
    ) -> WordPathResolution? {
        guard let panel = wordPathSnapshotTerminalPanel(
            workspace: workspace,
            terminalSurface: terminalSurface
        ),
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
        guard let panel = wordPathSnapshotTerminalPanel(
            workspace: workspace,
            terminalSurface: terminalSurface
        ),
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
        runtimeOutcome: TerminalCommandClickReleaseRouter.RuntimeOutcome
    ) -> WordPathResolution? {
        guard let surface else { return nil }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: modifierFlags)
        let cmdHeld = modifierFlags.contains(.command)
        let ghosttyConsumed = runtimeOutcome != .unhandled
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

        var resolvedPath: WordPathResolution?
        let route = commandClickReleaseRouter.route(
            commandHeld: cmdHeld,
            pathFallbackSuppressed: suppressCommandPathHover,
            runtimeOutcome: runtimeOutcome
        ) { [self] in
            guard let resolution = resolveWordUnderCursorPath(at: resolvedPoint) else { return nil }
            resolvedPath = resolution
            return TerminalCommandClickReleaseRouter.ResolvedPath(
                path: resolution.path,
                source: resolution.source == .snapshot ? .snapshot : .quicklook
            )
        }

        switch route {
        case .runtimeOpenURL:
#if DEBUG
            runtimeDebugLog(
                hypothesisID: "h3",
                name: "command_click_release",
                expected: "a runtime URL action exclusively owns the release",
                actual: "runtime_open_url_owned",
                data: [
                    "flags": debugModifierString(modifierFlags),
                    "ghostty_consumed": ghosttyConsumed,
                    "point_x": point.x,
                    "point_y": point.y
                ]
            )
#endif
            return nil
        case .none:
#if DEBUG
            if let resolution = resolvedPath {
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
            } else {
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
            }
#endif
            return nil
        case .pathFallback:
            break
        }

        guard let resolution = resolvedPath else { return nil }

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
           workspace.canResolveTerminalPathsAgainstLocalFilesystem(
               surfaceID: termSurface.id
           ),
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
        _ = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )

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

        _ = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_RELEASE,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )
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
        let pressHandled = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: mods
        )
        let release = dispatchCommandClickRelease(
            surface: surface,
            at: clampedPoint,
            modifierFlags: flags,
            mouseMods: mods
        )

        var payload: [String: Any] = [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": release.consumed ? "1" : "0",
        ]
        if let resolution = release.resolution {
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
        guard let cmdDown = makeFlagsChangedEvent(commandDown: true, at: clampedPoint),
              let cmdUp = makeFlagsChangedEvent(commandDown: false, at: clampedPoint) else {
            return ["error": "Failed to construct flagsChanged events"]
        }

        window?.makeFirstResponder(self)
        ghostty_surface_mouse_pos(surface, clampedPoint.x, bounds.height - clampedPoint.y, noMods)
        flagsChanged(with: cmdDown)
        let pressHandled = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_LEFT,
            mods: commandMods
        )
        let release = dispatchCommandClickRelease(
            surface: surface,
            at: clampedPoint,
            modifierFlags: flags,
            mouseMods: commandMods
        )
        flagsChanged(with: cmdUp)

        return [
            "pressHandled": pressHandled ? "1" : "0",
            "releaseConsumed": release.consumed ? "1" : "0",
        ]
    }

    private func makeFlagsChangedEvent(commandDown: Bool, at pointInView: NSPoint) -> NSEvent? {
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
        if routeInputDuringClipboardRead(event) { return }
        reconcileGhosttyMouseButtons(
            reason: "rightMouseDown.preflight",
            forceButtons: Set([.right])
        )
        focusFromPointerDown()
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }

        let mouseState = rememberGhosttyMouseState(from: event)
        ghostty_surface_mouse_pos(surface, mouseState.surfacePoint.x, mouseState.surfacePoint.y, mouseState.mods)
        _ = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_RIGHT,
            mods: mouseState.mods
        )
        _ = markGhosttyMouseButtonPressed(.right)
    }

    override func rightMouseUp(with event: NSEvent) {
        if routeInputDuringClipboardRead(event) { return }
        synchronizeGhosttyMouseSurfaceIdentity()
        let surfaceIdentity = currentGhosttyMouseSurfaceIdentity
        let session = ghosttyMouseSessionLedger.session(
            for: .right,
            on: surfaceIdentity
        )
        let mouseState = rememberGhosttyMouseState(from: event)
        guard let surface else {
            if let session { _ = finishGhosttyMouseSession(session) }
            return
        }
        let mouseCaptured = ghostty_surface_mouse_captured(surface)
        if session != nil,
           currentGhosttyMouseSurfaceIdentity == surfaceIdentity {
            _ = sendGhosttyMouseButton(
                surface,
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mouseState.mods
            )
            if let session {
                _ = finishGhosttyMouseSession(session)
            }
        }
        if !mouseCaptured {
            super.rightMouseUp(with: event)
            return
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        if routeInputDuringClipboardRead(event) { return }
        reconcileGhosttyMouseButtons(
            reason: "otherMouseDown.preflight",
            forceButtons: Set([.middle])
        )
        terminalSurface?.didReceiveExplicitInput()
        requestPointerFocusRecovery()
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        terminalSurface?.didAcceptExplicitInput()
        let mouseState = rememberGhosttyMouseState(from: event)
        ghostty_surface_mouse_pos(surface, mouseState.surfacePoint.x, mouseState.surfacePoint.y, mouseState.mods)
        _ = sendGhosttyMouseButton(
            surface,
            state: GHOSTTY_MOUSE_PRESS,
            button: GHOSTTY_MOUSE_MIDDLE,
            mods: mouseState.mods
        )
        _ = markGhosttyMouseButtonPressed(.middle)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        if routeInputDuringClipboardRead(event) { return }
        synchronizeGhosttyMouseSurfaceIdentity()
        let surfaceIdentity = currentGhosttyMouseSurfaceIdentity
        let session = ghosttyMouseSessionLedger.session(
            for: .middle,
            on: surfaceIdentity
        )
        let mouseState = rememberGhosttyMouseState(from: event)
        guard let surface else {
            if let session { _ = finishGhosttyMouseSession(session) }
            return
        }
        if session != nil,
           currentGhosttyMouseSurfaceIdentity == surfaceIdentity {
            _ = sendGhosttyMouseButton(
                surface,
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mouseState.mods
            )
            if let session {
                _ = finishGhosttyMouseSession(session)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu(for: event, sendsTerminalPointerEvent: true)
    }

    /// Builds the terminal's cmux context menu for pane chrome outside the
    /// terminal viewport without sending an out-of-bounds mouse event to Ghostty.
    func paneContextMenu(for event: NSEvent) -> NSMenu? {
        makeContextMenu(for: event, sendsTerminalPointerEvent: false)
    }

    private func makeContextMenu(
        for event: NSEvent,
        sendsTerminalPointerEvent: Bool
    ) -> NSMenu? {
        removeContextMenuEndObserver()
        guard let initialSurface = surface else { return nil }
        if sendsTerminalPointerEvent, ghostty_surface_mouse_captured(initialSurface) {
            // A terminal that owns a captured right drag must keep that drag
            // alive; no context menu is created for the captured protocol.
            return nil
        }
        reconcileGhosttyMouseButtons(
            reason: "menu.preflight",
            forceButtons: Set([.right])
        )
        window?.makeFirstResponder(self)
        guard let surface = surface else { return nil }
        if sendsTerminalPointerEvent, ghostty_surface_mouse_captured(surface) {
            return nil
        }
        let mouseState = rememberGhosttyMouseState(from: event)
        var contextMenuSession: GhosttyMouseSessionLedger.Session?
        if sendsTerminalPointerEvent {
            ghostty_surface_mouse_pos(surface, mouseState.surfacePoint.x, mouseState.surfacePoint.y, mouseState.mods)
            _ = sendGhosttyMouseButton(
                surface,
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mouseState.mods
            )
            _ = markGhosttyMouseButtonPressed(.right)
            contextMenuSession = ghosttyMouseSessionLedger.session(
                for: .right,
                on: currentGhosttyMouseSurfaceIdentity
            )
        }

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
            addTranslateSelectionMenuItem(to: menu, surface: surface)
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
        if let contextMenuSession {
            observeContextMenuEnd(menu, session: contextMenuSession)
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
            return controller.handleMirrorSplitRequested(surfaceId: surfaceId, vertical: !direction.isHorizontal, focusIntent: .focusCreatedPane)
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
        _ = terminalSurface?.performExplicitInputBindingAction("reset")
    }
    override func mouseMoved(with event: NSEvent) {
        if routeInputDuringClipboardRead(event) { return }
        reconcileGhosttyMouseButtons(reason: "mouseMoved")
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let mouseState = rememberGhosttyMouseState(from: event)
        let eventPoint = mouseState.localPoint
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            mouseState.surfacePoint.x,
            mouseState.surfacePoint.y,
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
        if routeInputDuringClipboardRead(event) { return }
        super.mouseEntered(with: event)
        reconcileGhosttyMouseButtons(reason: "mouseEntered")
        maybeRequestFirstResponderForMouseFocus()
        guard let surface = surface else { return }
        let suppressCommandPathHover = shouldSuppressCommandPathHover(for: event.modifierFlags)
        let mouseState = rememberGhosttyMouseState(from: event)
        let eventPoint = mouseState.localPoint
        trackMousePointIfUsable(eventPoint)
        ghostty_surface_mouse_pos(
            surface,
            mouseState.surfacePoint.x,
            mouseState.surfacePoint.y,
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
        if routeInputDuringClipboardRead(event) { return }
        reconcileGhosttyMouseButtons(reason: "mouseExited")
        if wordPathHoverActive {
            wordPathHoverActive = false
            NSCursor.pop()
        }
        guard let surface = surface else { return }
        if !ghosttyMouseSessionLedger.activeButtons.isEmpty {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, mouseModsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        if routeInputDuringClipboardRead(event) { return }
        synchronizeGhosttyMouseSurfaceIdentity()
        guard let surface = surface else { return }
        let mouseState = rememberGhosttyMouseState(from: event)
        let eventPoint = mouseState.localPoint
        trackMousePointIfUsable(eventPoint)
        // Forward the raw drag coordinates, including out-of-bounds positions.
        // Selection auto-scroll depends on libghostty observing the pointer leave
        // the viewport rather than a cached in-bounds hover point.
        ghostty_surface_mouse_pos(surface, mouseState.surfacePoint.x, mouseState.surfacePoint.y, mouseState.mods)
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
        if routeInputDuringClipboardRead(event) { return }
        reconcileGhosttyMouseButtons(reason: "scrollWheel")
        guard let surface else {
            // Detached views used by previews and tests have no runtime
            // snapshot. Preserve the bounded first-packet fallback for them.
            postWheelScroll(requiresAuthoritativeResponse: true)
            if let authoritativeScrollbar = authoritativeScrollbarSnapshot() {
                // The synchronous snapshot supersedes any callback payload
                // that was queued before this wheel event.
                discardPendingScrollbar()
                publishScrollbarUpdate(
                    authoritativeScrollbar,
                    isAuthoritativeWheelResponse: true
                )
                return
            }
            _ = flushPendingScrollbarIfAvailable()
            postWheelScroll(
                requiresAuthoritativeResponse: false,
                authoritativeResponseUnavailable: true
            )
            return
        }
        _ = rememberGhosttyMouseState(from: event)
        postWheelScroll(requiresAuthoritativeResponse: true)
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

        guard let authoritativeScrollbar = authoritativeScrollbarSnapshot() else {
            // Surface teardown can race input delivery. Cancel the pending
            // request and discard queued geometry; publishing stale geometry
            // here would move the viewport to an obsolete row space.
            discardPendingScrollbar()
            postWheelScroll(
                requiresAuthoritativeResponse: false,
                authoritativeResponseUnavailable: true
            )
            return
        }
        publishScrollbarUpdate(
            authoritativeScrollbar,
            isAuthoritativeWheelResponse: true
        )
    }

    deinit {
        discardPendingExplicitKeyDownEvents()
        discardPendingPasteAfterSurfaceReady()
        keyboardCopyModeRenderedFrameDemandRelease?()
        selectionAccessibilitySignal.finish()
        if titleUpdateSurfaceKey != nil {
            titleUpdateIngress.retireCurrentAttachment()
        }
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
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
        }
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        deferredGhosttyMouseRepairTask?.cancel()
        if let mouseUpEventMonitor {
            NSEvent.removeMonitor(mouseUpEventMonitor)
        }
        if let globalMouseUpEventMonitor {
            NSEvent.removeMonitor(globalMouseUpEventMonitor)
        }
        if let applicationResignActiveObserver {
            NotificationCenter.default.removeObserver(applicationResignActiveObserver)
        }
        if let contextMenuEndObserver {
            NotificationCenter.default.removeObserver(contextMenuEndObserver)
        }
        // Native session release happens in `viewWillMove(toWindow:)` on the
        // AppKit UI thread. Deinit must remain nonisolated: only cancel tasks,
        // remove observers, and invalidate the local ledger here.
        deferredGhosttyMouseRepairTask = nil
        ghosttyMouseSessionLedger.invalidate()
        removeMouseUpEventMonitorIfUnused()
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

    /// Applies `TerminalRendererWindowVisibility` for the hosting window. The
    /// occlusion `.visible` bit is remembered per window so the rule can tell a
    /// trustworthy occlusion verdict from a virtual display that never sets it.
    private func applyRendererWindowVisibility(for window: NSWindow) {
        let occlusionVisible = window.occlusionState.contains(.visible)
        if occlusionVisible {
            Self.windowsThatReportedVisible.add(window)
        }
        terminalSurface?.setRendererWindowVisible(
            TerminalRendererWindowVisibility.isVisible(
                occlusionVisible: occlusionVisible,
                windowHasReportedVisible: Self.windowsThatReportedVisible.contains(window),
                isWindowVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isOnActiveSpace: window.isOnActiveSpace,
                isKeyWindow: window.isKeyWindow
            )
        )
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        applyRendererWindowVisibility(for: window)
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
        onCancel: @escaping () -> Void = {},
        onTextCompletion: @escaping () -> Void = {}
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
                    if let self {
                        _ = self.deliverUploadResultText(
                            text,
                            onCompleted: onTextCompletion
                        )
                    } else {
                        onTextCompletion()
                    }
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
        let dragTypes = NSPasteboard(name: .drag).types ?? []
        guard let durableURLs = GhosttyApp.terminalPasteboard.durableDroppedFileURLs(
            urls,
            sourceIsTransient: PasteboardFileURLReader.hasPromisedFileURLType(
                dragTypes
            )
        ) else {
            return false
        }
        return executePreparedImageTransfer(
            .fileURLs(durableURLs),
            onCancel: {}
        )
    }

    @discardableResult
    fileprivate func insertDroppedPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        executePreparedImageTransfer(
            TerminalImageTransferPlanner.prepareSynchronously(
                pasteboard: pasteboard,
                mode: .drop
            ),
            onCancel: {}
        )
    }

    @discardableResult
    private func executePreparedImageTransfer(
        _ preparedContent: TerminalImageTransferPreparedContent,
        mode: TerminalImageTransferMode = .drop,
        onCancel: @escaping () -> Void
    ) -> Bool {
        switch preparedContent {
        case .reject:
            return false
        case .insertText(let text):
            return terminalSurface?.sendText(text) ?? false
        case .fileURLs(let fileURLs):
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: fileURLs,
                target: resolvedImageTransferTarget(),
                mode: mode
            )
            guard plan != .reject else {
                preparedContent.cleanupTransferredTemporaryFiles(
                    using: GhosttyApp.terminalPasteboard
                )
                return false
            }
            let onTextCompletion: () -> Void
            switch plan {
            case .insertText:
                onTextCompletion = {
                    preparedContent.cleanupTransferredTemporaryFiles(
                        using: GhosttyApp.terminalPasteboard
                    )
                }
            case .insertTextSegments(let segments, _):
                var remainingSegments = segments.count
                onTextCompletion = {
                    remainingSegments = max(0, remainingSegments - 1)
                    guard remainingSegments == 0 else { return }
                    preparedContent.cleanupTransferredTemporaryFiles(
                        using: GhosttyApp.terminalPasteboard
                    )
                }
            case .uploadFiles:
                // Upload callbacks own cleanup until the remote transfer has
                // finished (or failed), so do not consume ownership here.
                onTextCompletion = {}
            case .reject:
                onTextCompletion = {}
            }
            return executeImageTransferPlan(
                plan,
                onCancel: onCancel,
                onTextCompletion: onTextCompletion
            )
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
        if Self.hasLiveInternalDrag(in: sender.draggingPasteboard) {
            return []
        }
        if Self.filteredDropTypes(types).isDisjoint(with: Self.dropTypes) {
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
        if Self.hasLiveInternalDrag(in: sender.draggingPasteboard) {
            return []
        }
        if Self.filteredDropTypes(types).isDisjoint(with: Self.dropTypes) {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if Self.hasLiveInternalDrag(in: sender.draggingPasteboard) {
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
    static let ghosttySurfaceThemeDidChange = Notification.Name("ghosttySurfaceThemeDidChange")
    static let browserSearchFocus = Notification.Name("browserSearchFocus")
    static let workspaceRemoteConnectionPresentationDidChange = Notification.Name(
        "cmux.workspaceRemoteConnectionPresentationDidChange"
    )
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

private final class CloudTerminalReconnectOverlayView: NSView {
    var onReconnect: (() -> Void)?

    private let cardView = NSVisualEffectView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let spinner = NSProgressIndicator(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let reconnectButton = NSButton(frame: .zero)
    private var currentPresentation: CloudTerminalReconnectOverlayPolicy.Presentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        autoresizingMask = [.width, .height]

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.material = .hudWindow
        cardView.blendingMode = .withinWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 12
        cardView.layer?.masksToBounds = true
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        addSubview(cardView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        iconView.contentTintColor = NSColor.secondaryLabelColor

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        reconnectButton.title = String(localized: "cloud.overlay.reconnect.button", defaultValue: "Reconnect")
        reconnectButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil
        )
        reconnectButton.imagePosition = .imageLeading
        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .regular
        reconnectButton.target = self
        reconnectButton.action = #selector(handleReconnect)

        let stack = NSStackView(views: [iconView, spinner, titleLabel, detailLabel, reconnectButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        cardView.addSubview(stack)

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: centerYAnchor),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            cardView.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            stack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -24),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            spinner.widthAnchor.constraint(equalToConstant: 24),
            spinner.heightAnchor.constraint(equalToConstant: 24),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        if let buttonHit = reconnectButton.hitTest(convert(point, to: reconnectButton)) {
            return buttonHit
        }
        if cardView.frame.contains(point) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let pointInButton = reconnectButton.convert(event.locationInWindow, from: nil)
        if reconnectButton.isHidden == false,
           reconnectButton.bounds.contains(pointInButton) {
            onReconnect?()
        }
    }

    func apply(_ presentation: CloudTerminalReconnectOverlayPolicy.Presentation) {
        guard currentPresentation != presentation else { return }
        currentPresentation = presentation
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        reconnectButton.isHidden = !presentation.showsReconnectButton
        spinner.isHidden = !presentation.showsProgress
        iconView.isHidden = presentation.showsProgress
        if presentation.showsProgress {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        iconView.image = NSImage(
            systemSymbolName: presentation.showsReconnectButton ? "wifi.exclamationmark" : "arrow.triangle.2.circlepath",
            accessibilityDescription: nil
        )
    }

    @objc private func handleReconnect() {
        onReconnect?()
    }
}

final class GhosttySurfaceScrollView: NSView {
    enum FlashStyle {
        case navigation
        case notification
    }

    private static let flashAnimationKey = "cmux.flash"

    static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> FlashStyle {
        switch reason {
        case .navigation, .userInitiated:
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
    private let backgroundView: TerminalPaneBackgroundView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    let surfaceView: GhosttyNSView
    private let mobileViewportBorderOverlayView = TerminalViewportBorderOverlayView(frame: .zero)
    private let inactiveOverlayView: GhosttyFlashOverlayView
    private let dropZoneOverlayView: GhosttyFlashOverlayView
    private let paneDropTargetView = TerminalPaneDropTargetView(frame: .zero)
    private let notificationRingOverlayView: GhosttyFlashOverlayView
    private let notificationRingLayer: CAShapeLayer
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    private var cloudTerminalReconnectOverlayView: CloudTerminalReconnectOverlayView?
    private var hasVisibilityRevealRefreshScheduled = false
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
    private var workspaceAttentionColor = WorkspaceAttentionColor(configuredHex: nil)
    private var workspaceAttentionNSColor = NSColor.systemBlue
    private let keyboardCopyModeBadgeContainerView: GhosttyFlashOverlayView
    private let keyboardCopyModeBadgeView: GhosttyPassthroughVisualEffectView
    private let keyboardCopyModeBadgeIconView: NSImageView
    private let keyboardCopyModeBadgeLabel: NSTextField
    let linkHoverIndicatorView: TerminalLinkHoverIndicatorView
    private let imageTransferIndicatorContainerView: NSView
    private let imageTransferIndicatorView: NSVisualEffectView
    private let imageTransferIndicatorSpinner: NSProgressIndicator
    private let imageTransferCancelButton: NSButton
    private var searchOverlayHostingView: NSHostingView<SurfaceSearchOverlay>?
    private let deferredSearchOverlayMutationScheduler = MainActorDeferredActionScheduler()
    private let imageTransferIndicatorShowScheduler = MainActorDeferredActionScheduler()
    private var activeImageTransferOperation: TerminalImageTransferOperation?
    private var activeImageTransferCancelHandler: (() -> Void)?
    private var lastSearchOverlayStateID: ObjectIdentifier?
    private var searchOverlayMutationGeneration: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var scrollbarTrackingArea: NSTrackingArea?
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    var notificationScrollRestoreState = NotificationScrollRestoreState()
    /// Single source of truth for terminal follow/review intent. Layout and
    /// document reflow may move AppKit bounds transiently, but they never write
    /// this state; only user scroll gestures, explicit restores, and
    /// authoritative Ghostty scrollbar packets do.
    private(set) var scrollbackViewportIntent: TerminalScrollbackViewportIntent = .followingOutput
    /// Threshold in points from bottom to consider "at bottom" (allows for minor float drift)
    private static let scrollToBottomThreshold: CGFloat = 5.0
    private var isActive = true
    private var lastFocusRefreshAt: CFTimeInterval = 0
    private var lastRequestedPortalOcclusionVisible: Bool?
    private var activeDropZone: DropZone?
    private var pendingDropZone: DropZone?
    private var chromePaletteObservation: ChromePaletteDropOverlayObservation?
    private var sessionContentWidthPresentation = SessionContentWidthPresentation.disabled
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    private var pendingAutomaticFirstResponderApply = false
    private var pendingAutomaticFirstResponderFocusTransactionId: UUID?
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

    func releaseOwnedPortalHost(hostId: ObjectIdentifier, instanceSerial: UInt64, reason: String) {
        surfaceView.terminalSurface?.releasePortalHostIfOwned(
            hostId: hostId,
            instanceSerial: instanceSerial,
            reason: reason
        )
    }

    func prepareOwnedPortalHostForTransientReattach(
        hostId: ObjectIdentifier,
        instanceSerial: UInt64,
        reason: String
    ) {
        surfaceView.terminalSurface?.preparePortalHostReplacementIfOwned(
            hostId: hostId,
            instanceSerial: instanceSerial,
            reason: reason
        )
    }

    init(surfaceView: GhosttyNSView) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif

        self.surfaceView = surfaceView
        backgroundView = TerminalPaneBackgroundView(frame: .zero)
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
        linkHoverIndicatorView = TerminalLinkHoverIndicatorView(frame: .zero)
        imageTransferIndicatorContainerView = NSView(frame: .zero)
        imageTransferIndicatorView = NSVisualEffectView(frame: .zero)
        imageTransferIndicatorSpinner = NSProgressIndicator(frame: .zero)
        imageTransferCancelButton = NSButton(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
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
        backgroundView.terminalSurfaceView = surfaceView
        backgroundView.terminalScrollView = scrollView
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
        let appDelegate = AppDelegate.shared
        chromePaletteObservation = ChromePaletteDropOverlayObservation(
            overlay: dropZoneOverlayView,
            initialPalette: appDelegate?.chromePalette
                ?? ChromePaletteRuntimeResolver(runtime: appDelegate?.settingsRuntime).resolve(),
            updates: appDelegate?.makeChromePaletteUpdates
        )
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        notificationRingOverlayView.wantsLayer = true
        notificationRingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        notificationRingOverlayView.layer?.masksToBounds = false
        notificationRingOverlayView.autoresizingMask = [.width, .height]
        let notificationRingStyle = WorkspaceAttentionCoordinator.notificationRingStyle
        let notificationRingColor = NSColor.systemBlue
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
        let flashColor = NSColor.systemBlue
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
        linkHoverIndicatorView.frame = bounds
        linkHoverIndicatorView.autoresizingMask = [.width, .height]
        addSubview(linkHoverIndicatorView)

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
            // Final user-gesture check to settle follow/review intent.
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
                self.surfaceView.discardPendingExplicitKeyDownEvents()
                self.surfaceView.discardPendingPasteAfterSurfaceReady()
                return
            }
            self.surfaceView.replayPendingInputIfReady()
            self.scheduleAutomaticFirstResponderApply(reason: "surfaceDidBecomeReady")
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .workspaceRemoteConnectionPresentationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceRemoteConnectionPresentationDidChange(notification)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidReceiveWheelScroll,
            object: surfaceView,
            // Every producer is ``GhosttyNSView.scrollWheel`` on the main
            // thread. Do not enqueue this arm operation: the following
            // authoritative snapshot must observe the new intent.
            queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                if notification.userInfo?[GhosttyNotificationKey.authoritativeWheelResponseUnavailable]
                    as? Bool == true {
                    self.scrollbackViewportIntent = self.scrollbackViewportIntent
                        .cancellingExplicitScrollbarSync()
                    self.cancelPendingNotificationScrollRestoreForUserInput()
                    return
                }
                let requiresAuthoritativeResponse =
                    notification.userInfo?[GhosttyNotificationKey.requiresAuthoritativeWheelResponse]
                    as? Bool == true
                self.beginExplicitScrollbarSync(
                    requiresAuthoritativeResponse: requiresAuthoritativeResponse
                )
                self.cancelPendingNotificationScrollRestoreForUserInput()
            }
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
        dropZoneOverlayView.removeFromSuperview()
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let overlay = cloudTerminalReconnectOverlayView,
           overlay.superview === self,
           let hit = overlay.hitTest(convert(point, to: overlay)) {
            return hit
        }
        return super.hitTest(point)
    }

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
    private func synchronizeGeometryAndContent(
        forceViewportSync: Bool? = nil,
        preservedReviewOriginY: CGFloat? = nil
    ) -> Bool {
        let preservedReviewOriginY = preservedReviewOriginY ?? {
            guard scrollbackViewportIntent.preservesViewportDuringPendingSync else { return nil }
            return max(scrollView.contentView.bounds.origin.y, 0)
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let didScrollbarAppearanceChange = synchronizeScrollbarAppearance()
        let previousSurfaceSize = surfaceView.frame.size
        if let sharedBackdropCutoutView {
            _ = setFrameIfNeeded(sharedBackdropCutoutView, to: bounds)
        }
        _ = setFrameIfNeeded(backgroundView, to: bounds)
        let contentFrame = sessionContentFrame
        _ = setFrameIfNeeded(scrollView, to: contentFrame)
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
        _ = setFrameIfNeeded(mobileViewportBorderOverlayView, to: contentFrame)
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
        _ = setFrameIfNeeded(linkHoverIndicatorView, to: contentFrame)
        if let cloudTerminalReconnectOverlayView {
            _ = setFrameIfNeeded(cloudTerminalReconnectOverlayView, to: contentFrame)
        }
        synchronizeCloudTerminalReconnectOverlay()
        if let overlay = searchOverlayHostingView {
            _ = setFrameIfNeeded(overlay, to: contentFrame)
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
        synchronizeScrollView(
            forceViewportSync: forceViewportSync,
            preservedReviewOriginY: preservedReviewOriginY
        )
        synchronizeSurfaceView()
        let didCoreSurfaceChange = synchronizeCoreSurface()
        return !sizeApproximatelyEqual(previousSurfaceSize, targetSize) || didCoreSurfaceChange
    }

    /// Updates terminal content geometry without shrinking pane-level overlays.
    func setSessionContentWidthPresentation(_ presentation: SessionContentWidthPresentation) {
        guard sessionContentWidthPresentation != presentation else { return }
        sessionContentWidthPresentation = presentation
        _ = synchronizeGeometryAndContent()
    }

    private var sessionContentFrame: CGRect {
        sessionContentWidthPresentation.contentFrame(in: bounds)
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

    private func handleWorkspaceRemoteConnectionPresentationDidChange(_ notification: Notification) {
        guard let terminalSurface = surfaceView.terminalSurface else {
            synchronizeCloudTerminalReconnectOverlay()
            return
        }
        if let workspace = notification.object as? Workspace,
           workspace.id != terminalSurface.tabId {
            return
        }
        synchronizeCloudTerminalReconnectOverlay()
    }

    private func currentCloudTerminalReconnectPresentation() -> CloudTerminalReconnectOverlayPolicy.Presentation? {
        guard let terminalSurface = surfaceView.terminalSurface,
              let workspace = terminalSurface.owningWorkspace() else {
            return nil
        }
        return workspace.cloudTerminalReconnectOverlayPresentation(forSurfaceId: terminalSurface.id)
    }

    private func synchronizeCloudTerminalReconnectOverlay() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.synchronizeCloudTerminalReconnectOverlay()
            }
            return
        }

        guard let presentation = currentCloudTerminalReconnectPresentation() else {
            cloudTerminalReconnectOverlayView?.removeFromSuperview()
            cloudTerminalReconnectOverlayView = nil
            return
        }

        let overlay: CloudTerminalReconnectOverlayView
        if let existing = cloudTerminalReconnectOverlayView {
            overlay = existing
        } else {
            overlay = CloudTerminalReconnectOverlayView(frame: sessionContentFrame)
            overlay.autoresizingMask = []
            cloudTerminalReconnectOverlayView = overlay
        }
        overlay.apply(presentation)
        overlay.onReconnect = { [weak self] in
            guard let terminalSurface = self?.surfaceView.terminalSurface,
                  let workspace = terminalSurface.owningWorkspace() else {
                return
            }
            _ = workspace.reconnectCloudTerminalSurface(surfaceId: terminalSurface.id)
        }
        overlay.frame = sessionContentFrame
        if overlay.superview !== self {
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
        updateImageTransferIndicatorZOrder(relativeTo: overlay)
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
        // Keep the drop-zone overlay outside the hosted terminal subtree so it cannot perturb layout.
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
        // Cheap app-owned gates first. The NSPasteboard(name: .drag) read
        // below is a synchronous XPC round trip to the pasteboard daemon;
        // unguarded it ran on every pane layout of every width commit during
        // sidebar divider drags (5% of main-thread time in a Time Profiler
        // capture) because divider drags also deliver drag mouse events.
        let dropZoneActive = activeDropZone != nil || pendingDropZone != nil
        let appOwnedDragActive =
            AppDelegate.shared?.sidebarWorkspaceDragRegistry.currentWorkspaceId != nil
        guard dropZoneActive || appOwnedDragActive else { return }

        let pasteboardTypes = NSPasteboard(name: .drag).types
        let hasTabDrag = pasteboardTypes?.contains(Self.tabTransferPasteboardType) == true
        let hasSidebarDrag = pasteboardTypes?.contains(Self.sidebarTabReorderPasteboardType) == true
        let eventType = NSApp.currentEvent?.type
        let hasActiveDrag =
            dropZoneActive ||
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
        if surfaceView.terminalSurface !== terminalSurface { setLinkHoverURL(nil) }
        surfaceView.attachSurface(terminalSurface)
        // Preserve the bootstrap 800x600 surface until portal reattach churn
        // has produced a real host size instead of a transient 1x1 placeholder.
        guard bounds.width > 1, bounds.height > 1 else { return }
        _ = synchronizeGeometryAndContent()
        synchronizeCloudTerminalReconnectOverlay()
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

    func setWorkspaceAttentionColor(_ color: WorkspaceAttentionColor) {
        guard color != workspaceAttentionColor else { return }
        workspaceAttentionColor = color
        workspaceAttentionNSColor = color.nsColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingLayer.strokeColor = workspaceAttentionNSColor.cgColor
        notificationRingLayer.shadowColor = workspaceAttentionNSColor.cgColor
        updateFlashAppearance(style: lastFlashStyle)
        CATransaction.commit()
    }

    private func cancelDeferredSearchOverlayMutation() {
        deferredSearchOverlayMutationScheduler.cancel()
    }

    private func scheduleDeferredSearchOverlayMutation(
        generation: UInt64,
        _ mutation: @escaping () -> Void
    ) {
        deferredSearchOverlayMutationScheduler.schedule { [weak self] in
            guard let self else { return }
            guard self.searchOverlayMutationGeneration == generation else { return }
            mutation()
        }
    }

    private func cancelImageTransferIndicatorShow() {
        imageTransferIndicatorShowScheduler.cancel()
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

        imageTransferIndicatorShowScheduler.schedule(after: .milliseconds(150)) { [weak self] in
            guard let self else { return }
            guard self.activeImageTransferOperation === operation else { return }
            guard !operation.isCancelled else { return }
            self.imageTransferIndicatorSpinner.startAnimation(nil)
            self.imageTransferIndicatorContainerView.isHidden = false
            self.updateImageTransferIndicatorZOrder(relativeTo: self.searchOverlayHostingView)
        }
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
            onNavigateSearch: { [weak terminalSurface] direction in
                _ = direction.perform { terminalSurface?.performExplicitInputBindingAction($0) ?? false }
            },
            onSearchTextChanged: { [weak terminalSurface] in terminalSurface?.didReceiveExplicitInput() },
            onFieldDidFocus: { [weak self, weak terminalSurface] in
                self?.searchFocusTarget = .searchField
                terminalSurface?.setFocus(false)
            },
            onClose: { [weak self, weak terminalSurface] in
                terminalSurface?.closeSearchFromExplicitInput()
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
        return workspace.isFocusedTerminalInputSurface(terminalSurface.id)
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
            _ = setFrameIfNeeded(overlay, to: sessionContentFrame)
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
                    overlay.frame = self.sessionContentFrame
                    overlay.autoresizingMask = []
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
            _ = setFrameIfNeeded(overlay, to: sessionContentFrame)
            updateKeyboardCopyModeBadgeZOrder(relativeTo: overlay)
            return
        }

        searchFocusTarget = .searchField
        let overlay = TerminalSearchOverlayHostingView(rootView: rootView, surfaceView: surfaceView)
        overlay.frame = sessionContentFrame
        overlay.autoresizingMask = []
        searchOverlayHostingView = overlay
        lastSearchOverlayStateID = searchStateID
        scheduleDeferredSearchOverlayMutation(generation: mutationGeneration) { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            guard self.searchOverlayHostingView === overlay else { return }
            overlay.removeFromSuperview()
            overlay.frame = self.sessionContentFrame
            overlay.autoresizingMask = []
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
        guard paneDropTargetView.dropContext != nil else { return nil }
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
        // Terminal BELs can arrive in bursts. Their persistent unread state is
        // recorded separately, so one in-flight visual flash is sufficient.
        // Navigation flashes remain restartable because they reflect explicit
        // user intent.
        if case .notification = style,
           flashLayer.animation(forKey: Self.flashAnimationKey) != nil {
            return
        }

        lastFlashStyle = style
        #if DEBUG
        if let surfaceId = surfaceView.terminalSurface?.id {
            Self.recordFlash(for: surfaceId)
        }
#endif
        updateFlashPath(style: style)
        updateFlashAppearance(style: style)
        flashLayer.removeAllAnimations()
        flashLayer.opacity = 0
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
        flashLayer.add(animation, forKey: Self.flashAnimationKey)
    }

    var isVisibleInUI: Bool { surfaceView.isVisibleInUI }
    func setVisibleInUI(_ visible: Bool) {
        let wasVisible = surfaceView.isVisibleInUI
        // Make the AppKit portal presentable before asking Ghostty to realize its
        // drawable. Ghostty remains occluded until after the enqueue below, so it
        // cannot draw into a released swap chain during this short transition.
        surfaceView.setVisibleInUI(visible)
        isHidden = !visible
        surfaceView.terminalSurface?.setRendererPortalVisible(visible)
        if wasVisible != visible, lastRequestedPortalOcclusionVisible != visible {
            lastRequestedPortalOcclusionVisible = visible
            // A portal reveal inside a hidden window (agent/socket-driven
            // workspace switches) must not lift occlusion; the window-level
            // observer replays it when the window returns on screen.
            surfaceView.terminalSurface?.applyVisibilityOcclusion(visible)
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
            if wasVisible {
                surfaceView.deferReleaseAllGhosttyMouseButtons(reason: "setVisibleInUI.false")
            }
            setLinkHoverURL(nil)
            // If we were focused, yield first responder.
            if let window = uiWindow, let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                window.makeFirstResponder(nil)
            }
        } else if !wasVisible {
            surfaceView.deferReconcileGhosttyMouseButtons(reason: "setVisibleInUI.true")
            // Workspace/sidebar selection can make an already-sized terminal visible again
            // without a portal frame delta or a focus handoff. Nudge the Metal layer with
            // the portal refresh path — but on the next main-queue turn: reveals arrive
            // from inside SwiftUI update/layout (updateNSView, viewDidMoveToWindow, the
            // geometry-callback rebind), where a synchronous display can wedge the main
            // thread in Metal against the still-open window transaction.
            scheduleVisibilityRevealRefresh()
            scheduleAutomaticFirstResponderApply(reason: "setVisibleInUI")
        }
    }

    private func scheduleVisibilityRevealRefresh() {
        guard !hasVisibilityRevealRefreshScheduled else { return }
        hasVisibilityRevealRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasVisibilityRevealRefreshScheduled = false
            guard self.surfaceView.isVisibleInUI else { return }
            self.refreshSurfaceNow(reason: "setVisibleInUI.deferred")
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
        if !active {
            surfaceView.cancelKeyboardCopyMode()
        }
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
        if active {
            if !wasActive {
                surfaceView.deferReconcileGhosttyMouseButtons(reason: "setActive.true")
                scheduleAutomaticFirstResponderApply(reason: "setActive")
            }
        } else {
            if wasActive {
                surfaceView.deferReleaseAllGhosttyMouseButtons(reason: "setActive.false")
            }
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

    func moveFocus(
        from previous: GhosttySurfaceScrollView? = nil,
        delay: TimeInterval? = nil,
        respectForeignFirstResponder: Bool = false,
        focusTransactionId: UUID? = nil
    ) {
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
            // Same contract as ensureFocus's default: reassert-style callers
            // (tab-selection convergence) must not steal from a legitimate
            // focus owner — the sidebar's inline-rename field editor was
            // killed ~240ms into every double-click rename by the async
            // selection pipeline landing through this path. Explicit
            // focus-the-terminal callers (find escape, tmux mirror) keep the
            // default and still take focus.
            if respectForeignFirstResponder,
               let firstResponder = window.firstResponder,
               shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
                   AppDelegate.shared?.isRightSidebarFocusResponder($0, in: window) == true
               }) {
#if DEBUG
                cmuxDebugLog("find.moveFocus.skip to=\(surfaceShort) reason=foreignFirstResponder")
#endif
                return
            }
            guard self.canRequestSurfaceFirstResponder(in: window, reason: "moveFocus") else { return }
            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }
            let previousFocusTransactionId = self.surfaceView.firstResponderFocusTransactionId
            self.surfaceView.firstResponderFocusTransactionId = focusTransactionId
            defer {
                self.surfaceView.firstResponderFocusTransactionId = previousFocusTransactionId
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

    func debugCanApplyMountedSearchFieldFocusRequest() -> Bool {
        canApplyMountedSearchFieldFocusRequest()
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
        respectForeignFirstResponder: Bool = true,
        focusTransactionId: UUID? = nil
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
            scheduleAutomaticFirstResponderApply(
                reason: "ensureFocus.notVisible",
                focusTransactionId: focusTransactionId
            )
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
            scheduleAutomaticFirstResponderApply(
                reason: "ensureFocus.hiddenOrTiny",
                focusTransactionId: focusTransactionId
            )
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
            let result = makeSurfaceViewFirstResponder(
                in: window,
                focusTransactionId: focusTransactionId
            )
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
            scheduleAutomaticFirstResponderApply(
                reason: "ensureFocus.inactiveTab",
                focusTransactionId: focusTransactionId
            )
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              tab.isFocusedTerminalInputSurface(surfaceId) else {
            scheduleAutomaticFirstResponderApply(
                reason: "ensureFocus.notInputTarget",
                focusTransactionId: focusTransactionId
            )
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
        let result = makeSurfaceViewFirstResponder(
            in: window,
            focusTransactionId: focusTransactionId
        )
#if DEBUG
        cmuxDebugLog(
            "focus.ensure.apply surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
            "tab=\(tabId.uuidString.prefix(5)) panel=\(surfaceId.uuidString.prefix(5)) " +
            "result=\(result ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
        )
#endif

        if !isSurfaceViewFirstResponder() {
            scheduleAutomaticFirstResponderApply(
                reason: "ensureFocus.afterMakeFirstResponder",
                focusTransactionId: focusTransactionId
            )
        } else {
            reassertTerminalSurfaceFocus(reason: "ensureFocus.afterMakeFirstResponder")
        }
    }

    private func makeSurfaceViewFirstResponder(
        in window: NSWindow,
        focusTransactionId: UUID?
    ) -> Bool {
        let previousFocusTransactionId = surfaceView.firstResponderFocusTransactionId
        surfaceView.firstResponderFocusTransactionId = focusTransactionId
        defer {
            surfaceView.firstResponderFocusTransactionId = previousFocusTransactionId
        }
        return window.makeFirstResponder(surfaceView)
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
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return false
        }
        return tab.isFocusedTerminalInputSurface(surfaceId)
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
            scheduleAutomaticFirstResponderApply(
                reason: "clearSuppressReparentFocus.hiddenOrTiny",
                focusTransactionId: surfaceView.firstResponderFocusTransactionId
            )
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
        scheduleAutomaticFirstResponderApply(
            reason: reason,
            focusTransactionId: surfaceView.firstResponderFocusTransactionId
        )
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
        scheduleAutomaticFirstResponderApply(
            reason: reason,
            focusTransactionId: surfaceView.firstResponderFocusTransactionId
        )
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
        return makeSurfaceViewFirstResponder(
            in: window,
            focusTransactionId: surfaceView.firstResponderFocusTransactionId
        )
    }

    private func scheduleAutomaticFirstResponderApply(
        reason: String,
        focusTransactionId: UUID? = nil
    ) {
        if let focusTransactionId {
            pendingAutomaticFirstResponderFocusTransactionId = focusTransactionId
        }
        guard !pendingAutomaticFirstResponderApply else { return }
        pendingAutomaticFirstResponderApply = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutomaticFirstResponderApply = false
            let focusTransactionId = self.pendingAutomaticFirstResponderFocusTransactionId
            self.pendingAutomaticFirstResponderFocusTransactionId = nil
#if DEBUG
            let surfaceShort = String(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")
            cmuxDebugLog("find.applyFirstResponder.defer surface=\(surfaceShort) reason=\(reason)")
#endif
            self.applyFirstResponderIfNeeded(focusTransactionId: focusTransactionId)
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
            scheduleAutomaticFirstResponderApply(
                reason: "\(reason).hiddenOrTiny",
                focusTransactionId: surfaceView.firstResponderFocusTransactionId
            )
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

    private func applyFirstResponderIfNeeded(focusTransactionId: UUID? = nil) {
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
        _ = makeSurfaceViewFirstResponder(
            in: window,
            focusTransactionId: focusTransactionId
        )
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
    /// This avoids the Screen Recording permission required by legacy window-list capture, making
    /// it suitable for debug socket tests running in headless/VM contexts.
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
        defer { surfaceView.terminalSurface?.rendererPresentationReadinessDidChange() }
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
        flashLayer.strokeColor = workspaceAttentionNSColor.cgColor
        flashLayer.shadowColor = workspaceAttentionNSColor.cgColor
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

    private func synchronizeScrollView(
        forceViewportSync: Bool? = nil,
        preservedReviewOriginY: CGFloat? = nil
    ) {
        var didChangeGeometry = false
        let originToPreserve = preservedReviewOriginY ?? {
            guard scrollbackViewportIntent.preservesViewportDuringPendingSync else { return nil }
            return max(scrollView.contentView.bounds.origin.y, 0)
        }()
        let targetDocumentHeight = documentHeight()
        if abs(documentView.frame.height - targetDocumentHeight) > 0.5 {
            documentView.frame.size.height = targetDocumentHeight
            didChangeGeometry = true
        }

        // A non-flipped clip view can be clamped to its live bottom when its
        // document or viewport height changes. Restore the pre-layout pixel
        // anchor while reviewing scrollback or waiting for a wheel response;
        // an authoritative Ghostty packet will replace it below.
        if forceViewportSync != true,
           scrollbackViewportIntent.preservesViewportDuringPendingSync,
           let originToPreserve {
            let maxOriginY = max(
                0,
                documentView.frame.height - scrollView.contentView.bounds.height
            )
            let preservedOrigin = CGPoint(
                x: 0,
                y: min(max(originToPreserve, 0), maxOriginY)
            )
            let currentOrigin = scrollView.contentView.bounds.origin
            if !pointApproximatelyEqual(currentOrigin, preservedOrigin) {
                scrollView.contentView.scroll(to: preservedOrigin)
                didChangeGeometry = true
            }
        }

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY = CGFloat(scrollbar.rowsBelowViewport) * cellHeight
                let targetOrigin = CGPoint(x: 0, y: offsetY)
                let currentOrigin = scrollView.contentView.bounds.origin
                let shouldAutoScroll = forceViewportSync ??
                    scrollbackViewportIntent.allowsPassiveScrollbarSync

                if shouldAutoScroll && !pointApproximatelyEqual(currentOrigin, targetOrigin) {
                    scrollView.contentView.scroll(to: targetOrigin)
                    didChangeGeometry = true
                }
                lastSentRow = Int(scrollbar.offset)
            }
        }

        if didChangeGeometry {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func beginExplicitScrollbarSync(
        requiresAuthoritativeResponse: Bool = false
    ) {
        scrollbackViewportIntent = scrollbackViewportIntent
            .beginningExplicitScrollbarSync(
                requiresAuthoritativeResponse: requiresAuthoritativeResponse
            )
    }

    /// Applies a direct viewport restore as one intent transition so a later
    /// passive bottom packet cannot overwrite a restored scrollback position.
    @discardableResult
    func prepareExplicitViewportRestore(
        isAtBottom: Bool
    ) -> TerminalScrollbackViewportIntent {
        let previousIntent = scrollbackViewportIntent
        scrollbackViewportIntent = scrollbackViewportIntent
            .resolvingExplicitViewportRestore(isAtBottom: isAtBottom)
        return previousIntent
    }

    func rollbackExplicitViewportRestore(
        to previousIntent: TerminalScrollbackViewportIntent
    ) {
        scrollbackViewportIntent = previousIntent
    }

    private func handleLiveScroll() {
        cancelPendingNotificationScrollRestoreForUserInput()
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let topBasedScrollOffset = max(
            documentHeight - visibleRect.origin.y - visibleRect.height,
            0
        )
        scrollbackViewportIntent = scrollbackViewportIntent.applyingUserScroll(
            distanceFromBottom: Double(max(visibleRect.origin.y, 0)),
            bottomThreshold: Double(Self.scrollToBottomThreshold)
        )

        let row = Int(topBasedScrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else { return }
        let preservedReviewOriginY = scrollbackViewportIntent.preservesViewportDuringPendingSync
            ? max(scrollView.contentView.bounds.origin.y, 0)
            : nil
        let cellHeight = surfaceView.cellSize.height
        let targetDistanceFromBottom = cellHeight > 0
            ? Double(scrollbar.rowsBelowViewport) * Double(cellHeight)
            : nil
        let syncDecision = scrollbackViewportIntent.applyingScrollbar(
            scrollbar,
            targetDistanceFromBottom: targetDistanceFromBottom,
            bottomThreshold: Double(Self.scrollToBottomThreshold),
            isAuthoritativeWheelResponse:
                notification.userInfo?[GhosttyNotificationKey.isAuthoritativeWheelResponse]
                    as? Bool == true
        )
        scrollbackViewportIntent = syncDecision.intent
        let wasVisible = scrollView.hasVerticalScroller
        surfaceView.scrollbar = scrollbar
        let isVisible = shouldShowTerminalScrollBar()
        if wasVisible != isVisible {
            _ = synchronizeGeometryAndContent(
                forceViewportSync: syncDecision.shouldSynchronizeViewport,
                preservedReviewOriginY: preservedReviewOriginY
            )
            restorePendingNotificationScrollPositionAfterScrollbarUpdate()
            return
        }
        synchronizeScrollView(
            forceViewportSync: syncDecision.shouldSynchronizeViewport,
            preservedReviewOriginY: preservedReviewOriginY
        )
        restorePendingNotificationScrollPositionAfterScrollbarUpdate()
    }

    @discardableResult
    private func synchronizeScrollbarAppearance() -> Bool {
        let shouldShowScrollBar = shouldShowTerminalScrollBar()
        let didChange =
            scrollView.hasVerticalScroller != shouldShowScrollBar ||
            scrollView.autohidesScrollers
        scrollView.hasVerticalScroller = shouldShowScrollBar
        // Keep the scroller visible whenever terminal scrollback exists. The
        // scroller style itself is intentionally left to AppKit, which follows
        // the user's Appearance > Show scroll bars preference and updates this
        // scroll view when NSScroller.preferredScrollerStyle changes.
        scrollView.autohidesScrollers = false
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
        // scroller preference. Update the hosted surface/document frames through
        // the same narrow path instead of running the full pane reconciliation,
        // which can perturb split-layout overlays during a system preference
        // change.
        scrollView.tile()
        synchronizeTerminalGeometryAfterScrollerStyleChange()
    }

    private func synchronizeTerminalGeometryAfterScrollerStyleChange() {
        scrollView.layoutSubtreeIfNeeded()
        let targetSize = scrollView.contentView.bounds.size
        let targetSurfaceFrame = CGRect(origin: surfaceView.frame.origin, size: targetSize)
        _ = setFrameIfNeeded(surfaceView, to: targetSurfaceFrame)
        let targetDocumentFrame = CGRect(
            origin: documentView.frame.origin,
            size: CGSize(width: scrollView.contentView.bounds.width, height: documentView.frame.height)
        )
        _ = setFrameIfNeeded(documentView, to: targetDocumentFrame)
        synchronizeSurfaceView()
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
        guard !chars.isEmpty else { return }
        terminalSurface?.didReceiveExplicitInput()
        recordDirectAgentHibernationTerminalInput()
        sendTextToSurfaceAfterInputNotification(
            chars,
            preserveLiteralEscape: preserveLiteralEscape
        )
    }

    private func sendTextToSurfaceAfterInputNotification(
        _ chars: String,
        preserveLiteralEscape: Bool
    ) {
        if deferRuntimeInputDuringClipboardRead(
            estimatedBytes: chars.utf8.count,
            replay: { [weak self] in
                self?.sendTextToSurfaceAfterInputNotification(
                    chars,
                    preserveLiteralEscape: preserveLiteralEscape
                )
            }
        ) {
            return
        }
        guard ensureSurfaceReadyForInput() != nil else { return }
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
            let committedText = bufferedText
            bufferedText.removeAll(keepingCapacity: true)
            sendCommittedTextChunk(committedText)
        }

        func sendControlKey(_ keycode: UInt32) {
            sendCommittedControlKey(keycode)
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

    private func sendCommittedTextChunk(_ text: String) {
        guard !text.isEmpty else { return }
        if deferRuntimeInputDuringClipboardRead(
            estimatedBytes: text.utf8.count,
            replay: { [weak self] in self?.sendCommittedTextChunk(text) }
        ) {
            return
        }
        guard let surface = ensureSurfaceReadyForInput() else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        text.withCString { pointer in
            keyEvent.text = pointer
            _ = sendGhosttyKey(surface, keyEvent)
        }
    }

    private func sendCommittedControlKey(_ keycode: UInt32) {
        if deferRuntimeInputDuringClipboardRead(
            estimatedBytes: MemoryLayout<UInt32>.size,
            replay: { [weak self] in self?.sendCommittedControlKey(keycode) }
        ) {
            return
        }
        guard let surface = ensureSurfaceReadyForInput() else { return }
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
    @Environment(\.workspaceAttentionColor) private var workspaceAttentionColor
    @Environment(\.paneDropZone) var paneDropZone

    let terminalSurface: TerminalSurface
    let paneId: PaneID
    var isActive: Bool = true
    var isVisibleInUI: Bool = true
    var ownershipGeneration: UInt64 = 0
    var isCurrentPaneOwner: @MainActor () -> Bool = { true }
    var portalZPriority: Int = 0
    var showsInactiveOverlay: Bool = false
    var showsUnreadNotificationRing: Bool = false
    var inactiveOverlayColor: NSColor = .clear
    var inactiveOverlayOpacity: Double = 0
    var searchState: TerminalSurface.SearchState? = nil
    var reattachToken: UInt64 = 0
    var sessionContentWidthPresentation = SessionContentWidthPresentation.disabled
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    final class HostContainerView: NSView {
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

    @MainActor
    final class Coordinator {
        var attachGeneration: Int = 0
        let portalReconciliationScheduler = TerminalPortalReconciliationScheduler()
        // Track the latest desired state so attach retries can re-apply focus after re-parenting.
        var desiredIsActive: Bool = true
        var desiredIsVisibleInUI: Bool = true
        var desiredShowsUnreadNotificationRing: Bool = false
        var desiredPortalZPriority: Int = 0
        var lastBoundHostId: ObjectIdentifier?
        var lastPaneDropZone: DropZone?
        var lastSynchronizedHostGeometryRevision: UInt64 = 0
        weak var hostedView: GhosttySurfaceScrollView?
        /// The owner-death wake-up. The surface's vacancy registry holds only
        /// a weak trampoline into this coordinator, so the real retry (and
        /// everything it captures) dies with the representable.
        var vacancyRetry: (() -> Void)?
        /// The surface this representable last parked a wake-up on; dismantle
        /// removes the park through this because `hostedView` is weak and can
        /// already be gone by then.
        weak var vacancyParkedSurface: TerminalSurface?
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

    /// The complete immediate visible/active apply decision.
    ///
    /// Hiding never needs lease ownership or a live binding generation.
    /// Ownership gates SHOWING and re-anchoring; the host a hosted view is
    /// currently bound to is the only one that can un-show it, owner or not.
    /// Gating the hide on the claim leaves a deselected tab's surface on
    /// screen whenever ownership flips without a rebind: the bound host's
    /// visible=false updates defer forever and the hidden tab draws over the
    /// selected one.
    static func immediateHostedStateAction(
        hostOwnsPortal: Bool,
        portalBindingLive: Bool,
        desiredVisibleInUI: Bool,
        hostedViewHasSuperview: Bool,
        isBoundToCurrentHost: Bool
    ) -> GhosttyTerminalImmediateHostedStateAction {
        if portalBindingLive, hostOwnsPortal, shouldApplyImmediateHostedStateUpdate(
            desiredVisibleInUI: desiredVisibleInUI,
            hostedViewHasSuperview: hostedViewHasSuperview,
            isBoundToCurrentHost: isBoundToCurrentHost
        ) {
            return .applyVisibleAndActive
        }
        if !desiredVisibleInUI, isBoundToCurrentHost { return .hideOnly }
        return .deferred
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
        let workspaceAttentionColorSnapshot = workspaceAttentionColor
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
        let ownsCurrentPane = isCurrentPaneOwner()
        let portalExpectedSurfaceId = terminalSurface.id
        let portalExpectedGeneration = terminalSurface.portalBindingGeneration()
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
        coordinator.attachGeneration += 1
        let generation = coordinator.attachGeneration

        let reconciliationSnapshot = TerminalPortalReconciliationSnapshot(
            attachGeneration: generation,
            expectedSurfaceId: portalExpectedSurfaceId,
            expectedSurfaceGeneration: portalExpectedGeneration,
            paneId: paneId,
            ownershipGeneration: ownershipGeneration,
            isCurrentPaneOwner: isCurrentPaneOwner,
            workspaceAttentionColor: workspaceAttentionColorSnapshot,
            sessionContentWidthPresentation: sessionContentWidthPresentation,
            onFocus: onFocus,
            onTriggerFlash: onTriggerFlash,
            inactiveOverlayColor: inactiveOverlayColor,
            inactiveOverlayOpacity: inactiveOverlayOpacity,
            showsInactiveOverlay: showsInactiveOverlay,
            searchState: searchState,
            dropZone: forwardedDropZone
        )

        let stagePortalReconciliation: @MainActor (
            HostContainerView,
            TerminalPortalReconciliationReasons,
            String
        ) -> Void = { [weak coordinator, weak hostedView, weak terminalSurface] host, reasons, reason in
            guard let coordinator, let hostedView, let terminalSurface else { return }
            Self.stagePortalReconciliation(
                hostedView: hostedView,
                host: host,
                coordinator: coordinator,
                terminalSurface: terminalSurface,
                snapshot: reconciliationSnapshot,
                reasons: reasons,
                reason: reason
            )
        }

        if let host = hostContainer {
            host.onDidMoveToWindow = { [weak host] in
                guard let host else { return }
                stagePortalReconciliation(
                    host,
                    [.bindingRequired, .flushPendingManualSizeReport],
                    "didMoveToWindow"
                )
            }
            // The owner-death wake. Every claim above runs on this host's own
            // edges; the lease owner dying fires none of them, and a pane whose
            // owner dismantled can otherwise wait a full settle budget for an
            // unrelated SwiftUI update before it re-anchors. Parked only while
            // this host owns its pane AND its content is presented; the wake
            // re-checks both live and never writes visible/active state, so it
            // can re-anchor on-screen content but can never reveal a hidden
            // tab (bind is a show path — a hidden survivor waits for its own
            // update instead).
            // `parkPortalVacancyRetry` stores a closure on TerminalSurface, so
            // the retry body retains neither the surface nor its coordinator.
            let vacancyIsCurrentPaneOwner = isCurrentPaneOwner
            coordinator.vacancyRetry = { [weak host, weak coordinator] in
                guard let host, let coordinator else { return }
                guard vacancyIsCurrentPaneOwner() else { return }
                guard coordinator.desiredIsVisibleInUI else { return }
                stagePortalReconciliation(
                    host,
                    [.bindingRequired, .flushPendingManualSizeReport],
                    "hostVacated"
                )
            }
            if ownsCurrentPane, isVisibleInUI {
                // If an earlier update parked this host on a different surface,
                // unregister there first: the stale trampoline would fire THIS
                // coordinator's current retry, so a vacancy on the old surface
                // could drive a claim against the new one.
                if let previous = coordinator.vacancyParkedSurface, previous !== terminalSurface {
                    previous.removePortalVacancyRetry(
                        hostId: ObjectIdentifier(host),
                        instanceSerial: host.instanceSerial
                    )
                }
                coordinator.vacancyParkedSurface = terminalSurface
                let parkedAttachGeneration = generation
                let parkedRetry = coordinator.vacancyRetry
                terminalSurface.parkPortalVacancyRetry(
                    hostId: ObjectIdentifier(host),
                    instanceSerial: host.instanceSerial
                ) { [weak coordinator, weak terminalSurface] in
                    // TerminalSurface drains vacancy retries from RunLoop.main.
                    MainActor.assumeIsolated {
                        guard let coordinator,
                              let terminalSurface,
                              coordinator.attachGeneration == parkedAttachGeneration,
                              coordinator.vacancyParkedSurface === terminalSurface,
                              let parkedRetry else { return }
                        parkedRetry()
                    }
                }
            } else {
                coordinator.vacancyRetry = nil
                coordinator.vacancyParkedSurface?.removePortalVacancyRetry(hostId: ObjectIdentifier(host), instanceSerial: host.instanceSerial)
                coordinator.vacancyParkedSurface = nil
            }
#if DEBUG
            let geometryLogSurfaceId = terminalSurface.id.uuidString.prefix(5)
#endif
            host.onGeometryChanged = { [weak host, weak hostedView, weak coordinator] in
                guard let host, let hostedView, let coordinator else { return }
                guard coordinator.attachGeneration == generation else { return }
                guard reconciliationSnapshot.isCurrentPaneOwner() else { return }
                let hostId = ObjectIdentifier(host)
                let bindingRequired =
                    host.window != nil &&
                    (coordinator.lastBoundHostId != hostId ||
                     !TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: host))
#if DEBUG
                if bindingRequired {
                    cmuxDebugLog(
                        "ws.hostState.rebindOnGeometry surface=\(geometryLogSurfaceId) " +
                        "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                        "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                    )
                }
#endif
                stagePortalReconciliation(
                    host,
                    bindingRequired ? [.bindingRequired] : [],
                    "geometryChanged"
                )
            }

            if host.window != nil, ownsCurrentPane {
                let hostId = ObjectIdentifier(host)
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
                if shouldBindNow {
#if DEBUG
                    if portalEntryMissing {
                        cmuxDebugLog(
                            "ws.hostState.rebindOnUpdate surface=\(terminalSurface.id.uuidString.prefix(5)) " +
                            "reason=portalEntryMissing visible=\(coordinator.desiredIsVisibleInUI ? 1 : 0) " +
                            "active=\(coordinator.desiredIsActive ? 1 : 0) z=\(coordinator.desiredPortalZPriority)"
                        )
                    }
#endif
                    stagePortalReconciliation(
                        host,
                        [.bindingRequired],
                        "update"
                    )
                } else if coordinator.lastSynchronizedHostGeometryRevision != host.geometryRevision {
                    stagePortalReconciliation(host, [], "updateGeometry")
                }
            } else if ownsCurrentPane {
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
                stagePortalReconciliation(host, [], "updateDetached")
            }
        }

        // Every update publishes a complete latest-state reconciliation. More
        // specific callbacks above only add required work (binding or a pending
        // size report); the scheduler coalesces them into this latest closure.
        if let host = hostContainer {
            stagePortalReconciliation(host, [], "updateState")
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        coordinator.desiredIsActive = false
        coordinator.desiredIsVisibleInUI = false
        coordinator.desiredShowsUnreadNotificationRing = false
        coordinator.desiredPortalZPriority = 0
        coordinator.lastBoundHostId = nil
        coordinator.portalReconciliationScheduler.cancel()
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
            // The owner's vacate path drops its own wake-up; a candidate that
            // never owned has no vacate path, so drop it here — through the
            // coordinator's reference, since hostedView can already be gone.
            coordinator.vacancyRetry = nil
            coordinator.vacancyParkedSurface?.removePortalVacancyRetry(hostId: ObjectIdentifier(host), instanceSerial: host.instanceSerial)
            coordinator.vacancyParkedSurface = nil
            hostedView?.prepareOwnedPortalHostForTransientReattach(
                hostId: ObjectIdentifier(host),
                instanceSerial: host.instanceSerial,
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
