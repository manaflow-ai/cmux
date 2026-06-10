import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation

struct MultiWindowRouteCLIResult {
    let status: String
    let stdout: String
    let stderr: String
}

func runMultiWindowRouteCLI(
    cliURL: URL,
    socketPath: String,
    processEnv: [String: String],
    arguments: [String]
) -> MultiWindowRouteCLIResult {
    let process = Process()
    process.executableURL = cliURL
    process.arguments = ["--socket", socketPath] + arguments
    process.environment = processEnv

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return MultiWindowRouteCLIResult(status: "-1", stdout: "", stderr: String(describing: error))
    }
    process.waitUntilExit()

    let stdoutData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stdoutPipe.fileHandleForReading)
    let stderrData = ProcessPipeReader.readDataToEndOfFileOrEmpty(from: stderrPipe.fileHandleForReading)
    return MultiWindowRouteCLIResult(
        status: String(process.terminationStatus),
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

enum CmuxThemeNotifications {
    static let reloadConfig = Notification.Name("com.cmuxterm.themes.reload-config")
}

struct WorkspaceGroupNewWorkspaceTarget {
    let groupId: UUID
    let referenceWorkspaceId: UUID
    let placement: WorkspaceGroupNewPlacement
}

func isCommandPaletteFocusStealingTerminalOrBrowserResponder(_ responder: NSResponder) -> Bool {
    if responder is GhosttyNSView || responder is WKWebView {
        return true
    }

    if let textView = responder as? NSTextView, !textView.isFieldEditor {
        return isCommandPaletteFocusStealingTerminalOrBrowserView(textView)
    }

    if let view = responder as? NSView {
        return isCommandPaletteFocusStealingTerminalOrBrowserView(view)
    }

    return false
}

func isCommandPaletteFocusStealingTerminalOrBrowserView(_ view: NSView) -> Bool {
    if view is GhosttyNSView || view is GhosttySurfaceScrollView || view is WKWebView {
        return true
    }
    var current: NSView? = view.superview
    while let candidate = current {
        if candidate is GhosttyNSView || candidate is GhosttySurfaceScrollView || candidate is WKWebView {
            return true
        }
        current = candidate.superview
    }
    return false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation, NSMenuDelegate {
    nonisolated(unsafe) static var shared: AppDelegate?
    /// Stateless control-socket syscall layer (CmuxControlSocket); composition-root owned.
    nonisolated let socketTransport = SocketTransport()
    static let reloadConfigurationMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.cmux.reloadConfiguration")

    private static let cachedIsRunningUnderXCTest = detectRunningUnderXCTest(ProcessInfo.processInfo.environment)
    var isRunningUnderXCTestCached: Bool {
        Self.cachedIsRunningUnderXCTest
    }
    var cmuxThemePreviewReloadGeneration = 0
    var cmuxThemePreviewReloadWorkItem: DispatchWorkItem?

    private static func detectRunningUnderXCTest(_ env: [String: String]) -> Bool {
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if env.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        Self.detectRunningUnderXCTest(env)
    }

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    /// The auth graph, injected once via `configure(...)` at app startup.
    var auth: MacAuthComposition?
    /// Strongly-held observers for every active TabManager. Each observer owns
    /// Combine subscriptions that publish workspace.updated to mobile clients.
    var mobileWorkspaceListObservers: [ObjectIdentifier: MobileWorkspaceListObserver] = [:]

    /// The app's settings dependency container, handed over by `cmuxApp` via
    /// `configure(...)` before any main window is created. AppKit builds the
    /// main window's `NSHostingView` itself, so it injects this into the
    /// `ContentView` environment so `@LiveSetting` can resolve the stores it
    /// observes inside the sidebar.
    var settingsRuntime: SettingsRuntime?
    weak var fileExplorerState: FileExplorerState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    var shortcutLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    var workspaceObserver: NSObjectProtocol?
    var lifecycleSnapshotObservers: [NSObjectProtocol] = []
    var windowKeyObservers: [NSObjectProtocol] = []
    var shortcutMonitor: Any?
    var shortcutDefaultsObserver: NSObjectProtocol?
    var menuBarVisibilityObserver: NSObjectProtocol?
    var mobileHostSettingsObserver: NSObjectProtocol?
    var reloadConfigurationMenuItemRefreshScheduled = false
    var splitButtonTooltipRefreshScheduled = false
    var didScheduleGhosttyCrashBreadcrumbCheck = false
    var ghosttyCrashBreadcrumbTask: Task<Void, Never>?
    struct PendingConfiguredShortcutChord {
        let firstStroke: ShortcutStroke
        let windowNumber: Int?
    }
    var pendingConfiguredShortcutChord: PendingConfiguredShortcutChord?
    var activeConfiguredShortcutChordPrefixForCurrentEvent: ShortcutStroke?
    var shortcutEventFocusContextCache: ShortcutEventFocusContextCache?
    var ghosttyConfigObserver: NSObjectProtocol?
    var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    var ghosttyGotoSplitRightShortcut: StoredShortcut?
    var ghosttyGotoSplitUpShortcut: StoredShortcut?
    var ghosttyGotoSplitDownShortcut: StoredShortcut?
    var browserAddressBarFocusedPanelId: UUID?
    var browserOmnibarRepeatStartWorkItem: DispatchWorkItem?
    var browserOmnibarRepeatTickWorkItem: DispatchWorkItem?
    var browserOmnibarRepeatPanelId: UUID?
    var browserOmnibarRepeatKeyCode: UInt16?
    var browserOmnibarRepeatDelta: Int = 0
    var browserAddressBarFocusObserver: NSObjectProtocol?
    var browserAddressBarBlurObserver: NSObjectProtocol?
    var browserWebViewFirstResponderObserver: NSObjectProtocol?
    let updateLog = UpdateLogStore()
    let focusLog = FocusLogStore()
    lazy var updateController = UpdateController(log: updateLog)
    lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(updateLog: updateLog)
    let windowDecorationsController = WindowDecorationsController()
    var menuBarExtraController: MenuBarExtraController?
    var transientGlobalSearchMenuBarExtraController: MenuBarExtraController?
    var lastMenuBarExtraShouldInstall: Bool?
    lazy var mainWindowVisibilityController = MainWindowVisibilityController(
        dependencies: .init(
            isActivationSuppressed: {
                TerminalController.shouldSuppressSocketCommandActivation()
                    && !TerminalController.socketCommandAllowsInAppFocusMutations()
            },
            setActiveMainWindow: { [weak self] window in
                self?.setActiveMainWindow(window)
            }
        )
    )
    /// Live `cmux diff` viewer subprocesses, keyed by pid, retained until they exit.
    /// Declared outside `#if DEBUG` because process retention is production behavior.
    var diffViewerProcesses: [Int32: Process] = [:]

#if DEBUG
    var didSetupJumpUnreadUITest = false
    var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    var jumpUnreadFocusObserver: NSObjectProtocol?
    var didSetupTerminalCmdClickUITest = false
    var didSetupGotoSplitUITest = false
    var didSetupBonsplitTabDragUITest = false
    var didSetupTerminalViewportUITest = false
    var terminalCmdClickUITestPoller: DispatchSourceTimer?
    var bonsplitTabDragUITestRecorder: DispatchSourceTimer?
    var terminalViewportUITestRecorder: TerminalViewportUITestRecorder?
    var gotoSplitUITestRecorder: DispatchSourceTimer?
    var gotoSplitUITestObservers: [NSObjectProtocol] = []
    var didSetupMultiWindowNotificationsUITest = false
    var didSetupDisplayResolutionUITestDiagnostics = false
    var displayResolutionUITestObservers: [NSObjectProtocol] = []
    var didSetupFeedSidebarUITest = false
    var didStartFeedSidebarUITestPush = false
    var feedSidebarUITestObservers: [NSObjectProtocol] = []
    var didSetupPortalStatsUITestDiagnostics = false
    var portalStatsUITestObservers: [NSObjectProtocol] = []
    struct UITestRenderDiagnosticsSnapshot {
        let panelId: UUID
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }
    var debugCloseMainWindowConfirmationHandler: ((NSWindow) -> Bool)?
    /// Test seam: when set, ``openDiffViewerForFocusedWorkspace(for:)`` invokes this
    /// instead of spawning the bundled `cmux diff` CLI, so shortcut-dispatch tests can
    /// assert routing without launching a subprocess.
    var debugOpenDiffViewerHandler: (() -> Void)?
    var debugCreateMainWindowSourceIsNativeFullScreenOverride: Bool?
    // Keep debug-only windows alive when tests intentionally inject key mismatches.
    var debugDetachedContextWindows: [NSWindow] = []

    private func childExitKeyboardProbePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    func childExitKeyboardProbeHex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = childExitKeyboardProbePath() else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    var mainWindowControllers: [MainWindowController] = []

    /// Tracks the cascade point for new windows, matching Ghostty's upstream algorithm.
    /// Reset to `.zero` so the first window seeds the point from its own position.
    var lastCascadePoint = NSPoint.zero
    var startupSessionSnapshot: AppSessionSnapshot?
    var didPrepareStartupSessionSnapshot = false
    var didAttemptStartupSessionRestore = false
    var isApplyingSessionRestore = false
    var sessionAutosaveTimer: DispatchSourceTimer?
    var sessionAutosaveTickInFlight = false
    var sessionAutosaveDeferredRetryPending = false
    var processDetectedSessionSaveGeneration: UInt64 = 0
    let sessionPersistenceQueue = DispatchQueue(
        label: "com.cmuxterm.app.sessionPersistence",
        qos: .utility
    )
    private nonisolated static let launchServicesRegistrationQueue = DispatchQueue(
        label: "com.cmuxterm.app.launchServicesRegistration",
        qos: .utility
    )
    nonisolated static func enqueueLaunchServicesRegistrationWork(_ work: @escaping @Sendable () -> Void) {
        launchServicesRegistrationQueue.async(execute: work)
    }
    var lastSessionAutosaveFingerprint: Int?
    var lastSessionAutosavePersistedAt: Date = .distantPast
    var lastTypingActivityAt: TimeInterval = 0
    var didHandleExplicitOpenIntentAtStartup = false
    var didScheduleInitialMainWindowBootstrap = false
    var shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
    var didBootstrapInitialMainWindow = false
    var isTerminatingApp = false
    var closedWindowHistorySuppressedWindowIds: Set<UUID> = []
#if DEBUG
    var closeMainWindowContainingTabIdObserverForTesting: ((UUID, Bool) -> Void)?
#endif
    // Set to true when the user has already confirmed quit via the warning dialog,
    // so applicationShouldTerminate does not show a second alert.
    var isQuitWarningConfirmed = false
    var didInstallLifecycleSnapshotObservers = false
    var didDisableSuddenTermination = false
    var commandPaletteVisibilityByWindowId: [UUID: Bool] = [:]
    var commandPalettePendingOpenByWindowId: [UUID: Bool] = [:]
    var commandPaletteRecentRequestAtByWindowId: [UUID: TimeInterval] = [:]
    var commandPaletteEscapeSuppressionByWindowId: Set<UUID> = []
    var commandPaletteEscapeSuppressionStartedAtByWindowId: [UUID: TimeInterval] = [:]
    var commandPaletteSelectionByWindowId: [UUID: Int] = [:]
    var commandPaletteSnapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]
    static let commandPaletteRequestGraceInterval: TimeInterval = 1.25
    static let commandPalettePendingOpenMaxAge: TimeInterval = 8.0
    static let sessionAutosaveTypingQuietPeriod: TimeInterval = 0.65

    var updateViewModel: UpdateStateModel {
        updateController.model
    }

    override init() {
        super.init()
        Self.shared = self
    }

#if DEBUG
    private let debugColorWorkspaceTitlePrefix = "Debug Color - "
    private let debugPerfWorkspaceTitlePrefix = "Debug Perf - "
    private var debugStressWorkspaceCreationInProgress = false
    private var debugStressLagProbeEnabled = false
    private let debugStressWorkspaceCount = 20
    private let debugStressPaneCount = 4
    private let debugStressTabsPerPane = 4
    private let debugStressYieldInterval = 4
    private let debugStressSurfaceLoadTimeoutSeconds: TimeInterval = 10.0

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let minimumTargetBytes = 2_000_000
        let maximumTargetBytes = 200_000_000
        let minimumLineCount = 2000
        let effectiveLimit = max(config.scrollbackLimit, 0)
        let doubledLimit = min(effectiveLimit, maximumTargetBytes / 2) * 2
        let targetBytes = min(max(doubledLimit, minimumTargetBytes), maximumTargetBytes)
        // `%06d` guarantees at least a 6-digit field width. Any lines beyond
        // 999,999 only get wider, so this conservative floor always emits at
        // least `targetBytes` without oscillating at digit-count boundaries.
        let baseBytesPerLine = "scrollback 000000\n".utf8.count
        let lineCount = max((targetBytes + baseBytesPerLine - 1) / baseBytesPerLine, minimumLineCount)

        let command = #"awk 'BEGIN { for (i = 1; i <= \#(lineCount); ++i) printf "scrollback %06d\n", i }'"# + "\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    @objc func openDebugAgentSessionReact(_ sender: Any?) {
        openDebugAgentSession(rendererKind: .react)
    }

    @objc func openDebugAgentSessionSolid(_ sender: Any?) {
        openDebugAgentSession(rendererKind: .solid)
    }

    private func openDebugAgentSession(rendererKind: AgentSessionRendererKind) {
        guard let manager = activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        _ = workspace.newAgentSessionSurface(
            inPane: paneId,
            providerID: .codex,
            rendererKind: rendererKind,
            workingDirectory: workspace.currentDirectory,
            focus: true
        )
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        guard let tabManager else { return }

        let palette = WorkspaceTabColorSettings.palette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: Workspace] = [:]
        for tab in tabManager.tabs {
            guard let title = tab.customTitle,
                  title.hasPrefix(debugColorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab
        }

        for entry in palette {
            let title = "\(debugColorWorkspaceTitlePrefix)\(entry.name)"
            let targetTab: Workspace
            if let existing = existingByTitle[title] {
                targetTab = existing
            } else {
                targetTab = tabManager.addTab()
            }
            tabManager.setCustomTitle(tabId: targetTab.id, title: title)
            tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
        }
    }

    @objc func openDebugStressWorkspacesWithLoadedSurfaces(_ sender: Any?) {
        guard !debugStressWorkspaceCreationInProgress else { return }
        guard let tabManager else { return }

        debugStressLagProbeEnabled = true
        debugStressWorkspaceCreationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.debugStressWorkspaceCreationInProgress = false }

            let totalStart = ProcessInfo.processInfo.systemUptime
            let originalSelectedWorkspaceId = tabManager.selectedTabId
            var created: [Workspace] = []
            created.reserveCapacity(self.debugStressWorkspaceCount)
            var layoutFailures = 0
            var cumulativeWorkspaceMs: Double = 0
            var slowWorkspaceCount = 0
            var worstWorkspaceMs: Double = 0

            cmuxDebugLog(
                "stress.setup.start workspaces=\(self.debugStressWorkspaceCount) panes=\(self.debugStressPaneCount) " +
                "tabsPerPane=\(self.debugStressTabsPerPane) lagProbe=1"
            )

            for index in 0..<self.debugStressWorkspaceCount {
                let workspaceStart = ProcessInfo.processInfo.systemUptime
                let workspace = tabManager.addWorkspace(select: false, placementOverride: .end)
                created.append(workspace)
                tabManager.setCustomTitle(
                    tabId: workspace.id,
                    title: "\(self.debugPerfWorkspaceTitlePrefix)\(index + 1)"
                )

                if !(await self.configureDebugStressWorkspaceLayout(
                    workspace,
                    paneCount: self.debugStressPaneCount,
                    tabsPerPane: self.debugStressTabsPerPane
                )) {
                    layoutFailures += 1
                }

                let workspaceMs = (ProcessInfo.processInfo.systemUptime - workspaceStart) * 1000.0
                cumulativeWorkspaceMs += workspaceMs
                worstWorkspaceMs = max(worstWorkspaceMs, workspaceMs)
                if workspaceMs >= 35 {
                    slowWorkspaceCount += 1
                }

                if workspaceMs >= 35 || ((index + 1) % 5 == 0) {
                    let pending = self.pendingDebugTerminalSurfaceCount(in: created)
                    cmuxDebugLog(
                        "stress.setup.workspace idx=\(index + 1)/\(self.debugStressWorkspaceCount) " +
                        "ms=\(String(format: "%.2f", workspaceMs)) failures=\(layoutFailures) pending=\(pending)"
                    )
                }

                if ((index + 1) % self.debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }

            let creationElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let loadStats = await self.loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
                created,
                tabManager: tabManager
            )
            let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let avgWorkspaceMs = created.isEmpty ? 0 : (cumulativeWorkspaceMs / Double(created.count))
            let expectedSurfaceCount = self.debugStressWorkspaceCount
                * self.debugStressPaneCount
                * self.debugStressTabsPerPane
            if let originalSelectedWorkspaceId,
               tabManager.tabs.contains(where: { $0.id == originalSelectedWorkspaceId }) {
                tabManager.selectedTabId = originalSelectedWorkspaceId
            }

            cmuxDebugLog(
                "stress.setup.done createMs=\(String(format: "%.2f", creationElapsedMs)) " +
                "loadMs=\(String(format: "%.2f", loadStats.elapsedMs)) loadedPanels=\(loadStats.loadedPanels) " +
                "loadFailures=\(loadStats.failedPanels) totalMs=\(String(format: "%.2f", totalElapsedMs)) " +
                "workspaceAvgMs=\(String(format: "%.2f", avgWorkspaceMs)) workspaceWorstMs=\(String(format: "%.2f", worstWorkspaceMs)) " +
                "workspaceSlowCount=\(slowWorkspaceCount) waitAttempts=\(loadStats.attempts) " +
                "pendingSurfaces=\(loadStats.pendingSurfaces) expectedSurfaces=\(expectedSurfaceCount)"
            )

            NSLog(
                "Debug stress workspaces: created=%d panesPerWorkspace=%d tabsPerPane=%d expectedSurfaces=%d layoutFailures=%d pendingSurfaces=%d createMs=%.2f loadMs=%.2f loadedPanels=%d failedPanels=%d totalMs=%.2f workspaceAvgMs=%.2f workspaceWorstMs=%.2f waitAttempts=%d",
                self.debugStressWorkspaceCount,
                self.debugStressPaneCount,
                self.debugStressTabsPerPane,
                expectedSurfaceCount,
                layoutFailures,
                loadStats.pendingSurfaces,
                creationElapsedMs,
                loadStats.elapsedMs,
                loadStats.loadedPanels,
                loadStats.failedPanels,
                totalElapsedMs,
                avgWorkspaceMs,
                worstWorkspaceMs,
                loadStats.attempts
            )
        }
    }

    private func configureDebugStressWorkspaceLayout(
        _ workspace: Workspace,
        paneCount: Int,
        tabsPerPane: Int
    ) async -> Bool {
        guard let topLeftPanelId = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId else {
            return false
        }
        guard let topRight = workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topRight.id,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()

        let paneIds = workspace.bonsplitController.allPaneIds
        guard paneIds.count == paneCount else { return false }

        let additionalTabsPerPane = max(0, tabsPerPane - 1)
        if additionalTabsPerPane > 0 {
            for (paneIndex, paneId) in paneIds.enumerated() {
                for tabOffset in 0..<additionalTabsPerPane {
                    guard workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                        return false
                    }
                    if ((tabOffset + 1) % debugStressYieldInterval) == 0 {
                        await Task.yield()
                    }
                }
                if ((paneIndex + 1) % debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }
        }

        return true
    }

    private struct DebugStressSurfaceLoadStats {
        let pendingSurfaces: Int
        let loadedPanels: Int
        let failedPanels: Int
        let attempts: Int
        let elapsedMs: Double
    }

    private struct DebugStressTerminalLoadTarget {
        let workspace: Workspace
        let paneId: PaneID
        let tabId: TabID
        let panelId: UUID
    }

    private func waitForDebugStressCondition(
        timeout: TimeInterval,
        installObservers: (@escaping () -> Void) -> [NSObjectProtocol],
        evaluate: @escaping () -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var observers: [NSObjectProtocol] = []
            var timeoutWorkItem: DispatchWorkItem?
            var finished = false

            func cleanup() {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
            }

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                cleanup()
                continuation.resume(returning: result)
            }

            let trigger = {
                if evaluate() {
                    finish(true)
                }
            }

            observers = installObservers {
                DispatchQueue.main.async {
                    trigger()
                }
            }
            let workItem = DispatchWorkItem {
                finish(evaluate())
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
            trigger()
        }
    }

    private func loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
        _ workspaces: [Workspace],
        tabManager: TabManager
    ) async -> DebugStressSurfaceLoadStats {
        guard !workspaces.isEmpty else {
            return DebugStressSurfaceLoadStats(
                pendingSurfaces: 0,
                loadedPanels: 0,
                failedPanels: 0,
                attempts: 0,
                elapsedMs: 0
            )
        }

        let retainedWorkspaceIds = Set(workspaces.map(\.id))
        let loadStart = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        var queuedTargets: [DebugStressTerminalLoadTarget] = []
        queuedTargets.reserveCapacity(
            workspaces.count * debugStressPaneCount * debugStressTabsPerPane
        )

        tabManager.retainDebugWorkspaceLoads(for: retainedWorkspaceIds)
        defer { tabManager.releaseDebugWorkspaceLoads(for: retainedWorkspaceIds) }

        await Task.yield()
        forceDebugStressVisibleLayout()
        let mountedWorkspaceCount = await waitForDebugStressMountedWorkspaces(workspaces)

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for paneId in workspace.bonsplitController.allPaneIds {
                for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                    guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                          workspace.panel(for: tab.id) is TerminalPanel else {
                        continue
                    }
                    if workspace.preloadTerminalPanelForDebugStress(tabId: tab.id, inPane: paneId) != nil {
                        queuedTargets.append(
                            DebugStressTerminalLoadTarget(
                                workspace: workspace,
                                paneId: paneId,
                                tabId: tab.id,
                                panelId: panelId
                            )
                        )
                        attempts += 1
                    }
                }
            }

            cmuxDebugLog(
                "stress.setup.queue workspace=\(workspaceIndex + 1)/\(workspaces.count) " +
                "mounted=\(mountedWorkspaceCount)/\(workspaces.count) queued=\(queuedTargets.count)"
            )
            await Task.yield()
        }

        let waitResult = await waitForDebugStressTerminalPanelSurfaces(queuedTargets)
        attempts += waitResult.attempts
        let failedPanels = waitResult.pendingTargets.count
        let loadedPanels = max(0, queuedTargets.count - failedPanels)
        for target in waitResult.pendingTargets {
            cmuxDebugLog(
                "stress.setup.surfaceTimeout workspace=\(target.workspace.id.uuidString.prefix(5)) " +
                "panel=\(target.panelId.uuidString.prefix(5)) pane=\(target.paneId.id.uuidString.prefix(5))"
            )
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        return DebugStressSurfaceLoadStats(
            pendingSurfaces: pendingDebugTerminalSurfaceCount(in: workspaces),
            loadedPanels: loadedPanels,
            failedPanels: failedPanels,
            attempts: attempts,
            elapsedMs: elapsedMs
        )
    }

    private func waitForDebugStressMountedWorkspaces(_ workspaces: [Workspace]) async -> Int {
        guard !workspaces.isEmpty else { return 0 }
        var mountedWorkspaceCount = 0
        let selectedWorkspaceId = tabManager?.selectedTabId

        let updateMountedCount = { [self] in
            self.forceDebugStressVisibleLayout()
            mountedWorkspaceCount = 0
            for workspace in workspaces {
                if workspace.id == selectedWorkspaceId {
                    workspace.scheduleDebugStressTerminalGeometryReconcile()
                } else {
                    workspace.panels.values.compactMap { $0 as? TerminalPanel }.forEach { $0.surface.requestBackgroundSurfaceStartIfNeeded() }
                }
                if workspace.panels.values.contains(where: { panel in
                    guard let terminalPanel = panel as? TerminalPanel else { return false }
                    return terminalPanel.hostedView.superview != nil || terminalPanel.surface.surface != nil
                }) {
                    mountedWorkspaceCount += 1
                }
            }
        }
        let _ = await waitForDebugStressCondition(
            timeout: 0.25,
            installObservers: { trigger in
                [
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceDidBecomeReady,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceHostedViewDidMoveToWindow,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didUpdateNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    }
                ]
            },
            evaluate: {
                updateMountedCount()
                return mountedWorkspaceCount == workspaces.count
            }
        )

        cmuxDebugLog("stress.setup.mount mounted=\(mountedWorkspaceCount)/\(workspaces.count)")
        return mountedWorkspaceCount
    }

    private func waitForDebugStressTerminalPanelSurfaces(
        _ targets: [DebugStressTerminalLoadTarget]
    ) async -> (pendingTargets: [DebugStressTerminalLoadTarget], attempts: Int) {
        guard !targets.isEmpty else {
            return (pendingTargets: [], attempts: 0)
        }

        let deadline = Date().addingTimeInterval(debugStressSurfaceLoadTimeoutSeconds)
        let selectedWorkspaceId = tabManager?.selectedTabId
        var pendingTargets = targets
        var attempts = 0
        var eventCount = 0

        func refreshPendingTargets() {
            self.forceDebugStressVisibleLayout()
            var nextPending: [DebugStressTerminalLoadTarget] = []
            nextPending.reserveCapacity(pendingTargets.count)
            var startedThisPass = 0

            for target in pendingTargets {
                guard let terminalPanel = target.workspace.panel(for: target.tabId) as? TerminalPanel else {
                    nextPending.append(target)
                    continue
                }
                if terminalPanel.surface.surface != nil {
                    continue
                }

                let hostedView = terminalPanel.hostedView
                let shouldReconcileVisibleSelection =
                    target.workspace.id == selectedWorkspaceId &&
                    terminalPanel.surface.isViewInWindow &&
                    hostedView.superview != nil

                if shouldReconcileVisibleSelection {
                    target.workspace.scheduleDebugStressTerminalGeometryReconcile()
                    terminalPanel.requestViewReattach()
                }
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                startedThisPass += 1
                nextPending.append(target)
            }

            eventCount += 1
            if nextPending.count != pendingTargets.count || startedThisPass > 0 || eventCount == 1 {
                cmuxDebugLog(
                    "stress.setup.await event=\(eventCount) pending=\(nextPending.count) " +
                    "started=\(startedThisPass)"
                )
            }
            attempts += startedThisPass
            pendingTargets = nextPending
        }
        refreshPendingTargets()
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0, !pendingTargets.isEmpty {
            let _ = await waitForDebugStressCondition(
                timeout: remaining,
                installObservers: { trigger in
                    [
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceDidBecomeReady,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceHostedViewDidMoveToWindow,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: NSWindow.didUpdateNotification,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        }
                    ]
                },
                evaluate: {
                    refreshPendingTargets()
                    return pendingTargets.isEmpty
                }
            )
        }

        return (pendingTargets: pendingTargets, attempts: attempts)
    }

    private func forceDebugStressVisibleLayout() {
        if let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            activeWindow.contentView?.layoutSubtreeIfNeeded()
            activeWindow.contentView?.displayIfNeeded()
            return
        }

        for (windowIndex, window) in NSApp.windows.enumerated() {
            window.contentView?.layoutSubtreeIfNeeded()
            if windowIndex == 0 {
                window.contentView?.displayIfNeeded()
            }
        }
    }

    private func pendingDebugTerminalSurfaceCount(in workspaces: [Workspace]) -> Int {
        var pending = 0
        for workspace in workspaces {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if terminalPanel.surface.surface == nil {
                    pending += 1
                }
            }
        }
        return pending
    }

    private func debugStressLagSnapshot() -> (
        workspaceCount: Int,
        terminalPanelCount: Int,
        loadedSurfaceCount: Int,
        selectedWorkspace: String
    ) {
        guard let tabManager else {
            return (0, 0, 0, "nil")
        }
        var terminalPanelCount = 0
        var loadedSurfaceCount = 0
        for workspace in tabManager.tabs {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                terminalPanelCount += 1
                if terminalPanel.surface.surface != nil {
                    loadedSurfaceCount += 1
                }
            }
        }
        let selectedWorkspace = tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        return (
            tabManager.tabs.count,
            terminalPanelCount,
            loadedSurfaceCount,
            selectedWorkspace
        )
    }

    func logSlowShortcutMonitorLatencyIfNeeded(
        event: NSEvent,
        handledByShortcut: Bool,
        elapsedMs: Double
    ) {
        guard debugStressLagProbeEnabled else { return }
        guard event.type == .keyDown else { return }

        let normalizedFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainTyping = normalizedFlags.isDisjoint(with: [.command, .control, .option])
        let thresholdMs: Double = event.isARepeat ? 1.5 : (isPlainTyping ? 2.5 : 6.0)
        guard elapsedMs >= thresholdMs else { return }

        let snapshot = debugStressLagSnapshot()
        cmuxDebugLog(
            "stress.inputLag path=appMonitor ms=\(String(format: "%.2f", elapsedMs)) " +
            "threshold=\(String(format: "%.2f", thresholdMs)) handled=\(handledByShortcut ? 1 : 0) " +
            "plain=\(isPlainTyping ? 1 : 0) repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) " +
            "mods=\(event.modifierFlags.rawValue) workspaces=\(snapshot.workspaceCount) " +
            "terminals=\(snapshot.terminalPanelCount) surfacesReady=\(snapshot.loadedSurfaceCount) " +
            "selected=\(snapshot.selectedWorkspace)"
        )
    }

    @objc func triggerSentryTestCrash(_ sender: Any?) {
        SentrySDK.crash()
    }
#endif

}


// MARK: - CmuxUpdater seams
