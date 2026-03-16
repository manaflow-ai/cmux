import AppKit
import Bonsplit
import Combine
import CoreServices
import Darwin
import ObjectiveC.runtime
import Sentry
import SwiftUI
import UserNotifications
import WebKit

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation {
    // MARK: Nested Types

    struct ScriptableMainWindowState {
        let windowId: UUID
        let tabManager: TabManager
        let window: NSWindow?
    }

    struct SessionDisplayGeometry {
        let displayID: UInt32?
        let frame: CGRect
        let visibleFrame: CGRect
    }

    struct MainWindowSummary {
        let windowId: UUID
        let isKeyWindow: Bool
        let isVisible: Bool
        let workspaceCount: Int
        let selectedWorkspaceId: UUID?
    }

    struct WindowMoveTarget: Identifiable {
        // MARK: Properties

        let windowId: UUID
        let label: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        // MARK: Computed Properties

        var id: UUID {
            windowId
        }
    }

    struct WorkspaceMoveTarget: Identifiable {
        // MARK: Properties

        let windowId: UUID
        let workspaceId: UUID
        let windowLabel: String
        let workspaceTitle: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        // MARK: Computed Properties

        var id: String {
            "\(windowId.uuidString):\(workspaceId.uuidString)"
        }

        var label: String {
            isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
        }
    }

    private final class MainWindowContext {
        // MARK: Properties

        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        weak var window: NSWindow?

        // MARK: Lifecycle

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.window = window
        }
    }

    private final class MainWindowController: NSWindowController, NSWindowDelegate {
        // MARK: Properties

        var onClose: (() -> Void)?

        // MARK: Functions

        func windowWillClose(_: Notification) {
            onClose?()
        }
    }

    private struct PersistedWindowGeometry: Codable {
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    private enum ServiceOpenTarget {
        case window
        case workspace
    }

    // MARK: Static Properties

    static var shared: AppDelegate?

    private static let cachedIsRunningUnderXCTest = detectRunningUnderXCTest(ProcessInfo.processInfo.environment)

    private static let persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v1"

    private static let serviceErrorNoPath = NSString(string: String(localized: "error.clipboardFolderPath", defaultValue: "Could not load any folder path from the clipboard."))
    private static let didInstallWindowKeyEquivalentSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.performKeyEquivalent(with:))
        let swizzledSelector = #selector(NSWindow.cmux_performKeyEquivalent(with:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector)
        else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    private static let didInstallWindowFirstResponderSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeFirstResponder(_:))
        let swizzledSelector = #selector(NSWindow.cmux_makeFirstResponder(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector)
        else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    private static let didInstallWindowSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.sendEvent(_:))
        let swizzledSelector = #selector(NSWindow.cmux_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector)
        else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    private static let didInstallApplicationSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSApplication.self
        let originalSelector = #selector(NSApplication.sendEvent(_:))
        let swizzledSelector = #selector(NSApplication.cmux_applicationSendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector)
        else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    private static let socketListenerHealthCheckInterval: DispatchTimeInterval = .seconds(2)
    private static let socketListenerUnhealthyCaptureCooldown: TimeInterval = 60
    private nonisolated static let launchServicesRegistrationQueue = DispatchQueue(
        label: "com.cmuxterm.app.launchServicesRegistration",
        qos: .utility
    )
    private static let commandPaletteRequestGraceInterval: TimeInterval = 1.25
    private static let commandPalettePendingOpenMaxAge: TimeInterval = 8.0
    private static let sessionAutosaveTypingQuietPeriod: TimeInterval = 0.65

    // MARK: Properties

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    var shortcutLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)

    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleSnapshotObservers: [NSObjectProtocol] = []
    private var windowKeyObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var menuBarVisibilityObserver: NSObjectProtocol?
    private var splitButtonTooltipRefreshScheduled = false
    private var ghosttyConfigObserver: NSObjectProtocol?
    private var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    private var ghosttyGotoSplitRightShortcut: StoredShortcut?
    private var ghosttyGotoSplitUpShortcut: StoredShortcut?
    private var ghosttyGotoSplitDownShortcut: StoredShortcut?
    private var browserAddressBarFocusedPanelId: UUID?
    private var browserOmnibarRepeatStartWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatTickWorkItem: DispatchWorkItem?
    private var browserOmnibarRepeatKeyCode: UInt16?
    private var browserOmnibarRepeatDelta: Int = 0
    private var browserAddressBarFocusObserver: NSObjectProtocol?
    private var browserAddressBarBlurObserver: NSObjectProtocol?
    private let updateController = UpdateController()
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(viewModel: updateViewModel)
    private let windowDecorationsController = WindowDecorationsController()
    private var menuBarExtraController: MenuBarExtraController?

    #if DEBUG
        private var didSetupJumpUnreadUITest = false
        private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
        private var jumpUnreadFocusObserver: NSObjectProtocol?
        private var didSetupGotoSplitUITest = false
        private var gotoSplitUITestObservers: [NSObjectProtocol] = []
        private var didSetupMultiWindowNotificationsUITest = false
        var debugCloseMainWindowConfirmationHandler: ((NSWindow) -> Bool)?
        /// Keep debug-only windows alive when tests intentionally inject key mismatches.
        private var debugDetachedContextWindows: [NSWindow] = []

        private func childExitKeyboardProbePath() -> String? {
            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
                  let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
                  !path.isEmpty
            else {
                return nil
            }
            return path
        }

        private func childExitKeyboardProbeHex(_ value: String?) -> String {
            guard let value else { return "" }
            return value.unicodeScalars
                .map { String(format: "%04X", $0.value) }
                .joined(separator: ",")
        }

        private func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
            guard let path = childExitKeyboardProbePath() else { return }
            var payload: [String: String] = {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
                else {
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

    private var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    private var mainWindowControllers: [MainWindowController] = []
    private var startupSessionSnapshot: AppSessionSnapshot?
    private var didPrepareStartupSessionSnapshot = false
    private var didAttemptStartupSessionRestore = false
    private var isApplyingStartupSessionRestore = false
    private var sessionAutosaveTimer: DispatchSourceTimer?
    private var sessionAutosaveTickInFlight = false
    private var sessionAutosaveDeferredRetryPending = false
    private var socketListenerHealthTimer: DispatchSourceTimer?
    private var socketListenerHealthCheckInFlight = false
    private var lastSocketListenerUnhealthyCaptureAt: Date = .distantPast
    private let sessionPersistenceQueue = DispatchQueue(
        label: "com.cmuxterm.app.sessionPersistence",
        qos: .utility
    )
    private var lastSessionAutosaveFingerprint: Int?
    private var lastSessionAutosavePersistedAt: Date = .distantPast
    private var lastTypingActivityAt: TimeInterval = 0
    private var didHandleExplicitOpenIntentAtStartup = false
    private var isTerminatingApp = false
    private var didInstallLifecycleSnapshotObservers = false
    private var didDisableSuddenTermination = false
    private var commandPaletteVisibilityByWindowId: [UUID: Bool] = [:]
    private var commandPalettePendingOpenByWindowId: [UUID: Bool] = [:]
    private var commandPaletteRecentRequestAtByWindowId: [UUID: TimeInterval] = [:]
    private var commandPaletteEscapeSuppressionByWindowId: Set<UUID> = []
    private var commandPaletteEscapeSuppressionStartedAtByWindowId: [UUID: TimeInterval] = [:]
    private var commandPaletteSelectionByWindowId: [UUID: Int] = [:]
    private var commandPaletteSnapshotByWindowId: [UUID: CommandPaletteDebugSnapshot] = [:]

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
        private let debugStressSurfaceLoadPollNanoseconds: UInt64 = 25_000_000

        @objc func openDebugScrollbackTab(_: Any?) {
            guard let tabManager else { return }
            let tab = tabManager.addTab()
            let config = GhosttyConfig.load()
            let lineCount = min(max(config.scrollbackLimit * 2, 2000), 60000)
            let command = "for i in {1..\(lineCount)}; do printf \"scrollback %06d\\n\" $i; done\n"
            sendTextWhenReady(command, to: tab)
        }

        @objc func openDebugLoremTab(_: Any?) {
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

        @objc func openDebugColorComparisonWorkspaces(_: Any?) {
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
                let targetTab: Workspace = if let existing = existingByTitle[title] {
                    existing
                } else {
                    tabManager.addTab()
                }
                tabManager.setCustomTitle(tabId: targetTab.id, title: title)
                tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
            }
        }

        @objc func openDebugStressWorkspacesWithLoadedSurfaces(_: Any?) {
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
                created.reserveCapacity(debugStressWorkspaceCount)
                var layoutFailures = 0
                var cumulativeWorkspaceMs: Double = 0
                var slowWorkspaceCount = 0
                var worstWorkspaceMs: Double = 0

                dlog(
                    "stress.setup.start workspaces=\(debugStressWorkspaceCount) panes=\(debugStressPaneCount) " +
                        "tabsPerPane=\(debugStressTabsPerPane) lagProbe=1"
                )

                for index in 0..<debugStressWorkspaceCount {
                    let workspaceStart = ProcessInfo.processInfo.systemUptime
                    let workspace = tabManager.addWorkspace(select: false, placementOverride: .end)
                    created.append(workspace)
                    tabManager.setCustomTitle(
                        tabId: workspace.id,
                        title: "\(debugPerfWorkspaceTitlePrefix)\(index + 1)"
                    )

                    if await !configureDebugStressWorkspaceLayout(
                        workspace,
                        paneCount: debugStressPaneCount,
                        tabsPerPane: debugStressTabsPerPane
                    ) {
                        layoutFailures += 1
                    }

                    let workspaceMs = (ProcessInfo.processInfo.systemUptime - workspaceStart) * 1000.0
                    cumulativeWorkspaceMs += workspaceMs
                    worstWorkspaceMs = max(worstWorkspaceMs, workspaceMs)
                    if workspaceMs >= 35 {
                        slowWorkspaceCount += 1
                    }

                    if workspaceMs >= 35 || ((index + 1) % 5 == 0) {
                        let pending = pendingDebugTerminalSurfaceCount(in: created)
                        dlog(
                            "stress.setup.workspace idx=\(index + 1)/\(debugStressWorkspaceCount) " +
                                "ms=\(String(format: "%.2f", workspaceMs)) failures=\(layoutFailures) pending=\(pending)"
                        )
                    }

                    if ((index + 1) % debugStressYieldInterval) == 0 {
                        await Task.yield()
                    }
                }

                let creationElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
                let loadStats = await loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
                    created,
                    tabManager: tabManager
                )
                let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
                let avgWorkspaceMs = created.isEmpty ? 0 : (cumulativeWorkspaceMs / Double(created.count))
                let expectedSurfaceCount = debugStressWorkspaceCount
                    * debugStressPaneCount
                    * debugStressTabsPerPane
                if let originalSelectedWorkspaceId,
                   tabManager.tabs.contains(where: { $0.id == originalSelectedWorkspaceId })
                {
                    tabManager.selectedTabId = originalSelectedWorkspaceId
                }

                dlog(
                    "stress.setup.done createMs=\(String(format: "%.2f", creationElapsedMs)) " +
                        "loadMs=\(String(format: "%.2f", loadStats.elapsedMs)) loadedPanels=\(loadStats.loadedPanels) " +
                        "loadFailures=\(loadStats.failedPanels) totalMs=\(String(format: "%.2f", totalElapsedMs)) " +
                        "workspaceAvgMs=\(String(format: "%.2f", avgWorkspaceMs)) workspaceWorstMs=\(String(format: "%.2f", worstWorkspaceMs)) " +
                        "workspaceSlowCount=\(slowWorkspaceCount) waitAttempts=\(loadStats.attempts) " +
                        "pendingSurfaces=\(loadStats.pendingSurfaces) expectedSurfaces=\(expectedSurfaceCount)"
                )

                NSLog(
                    "Debug stress workspaces: created=%d panesPerWorkspace=%d tabsPerPane=%d expectedSurfaces=%d layoutFailures=%d pendingSurfaces=%d createMs=%.2f loadMs=%.2f loadedPanels=%d failedPanels=%d totalMs=%.2f workspaceAvgMs=%.2f workspaceWorstMs=%.2f waitAttempts=%d",
                    debugStressWorkspaceCount,
                    debugStressPaneCount,
                    debugStressTabsPerPane,
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
                              workspace.panel(for: tab.id) is TerminalPanel
                        else {
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

                dlog(
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
                dlog(
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

            for _ in 0..<4 {
                forceDebugStressVisibleLayout()
                mountedWorkspaceCount = 0
                for workspace in workspaces {
                    if workspace.id == selectedWorkspaceId {
                        workspace.scheduleDebugStressTerminalGeometryReconcile()
                    } else {
                        workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
                    }
                    if workspace.panels.values.contains(where: { panel in
                        guard let terminalPanel = panel as? TerminalPanel else { return false }
                        return terminalPanel.hostedView.superview != nil || terminalPanel.surface.surface != nil
                    }) {
                        mountedWorkspaceCount += 1
                    }
                }
                if mountedWorkspaceCount == workspaces.count {
                    break
                }
                await Task.yield()
                try? await Task.sleep(nanoseconds: debugStressSurfaceLoadPollNanoseconds)
            }

            dlog("stress.setup.mount mounted=\(mountedWorkspaceCount)/\(workspaces.count)")
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
            var pass = 0

            while !pendingTargets.isEmpty, Date() < deadline {
                pass += 1
                forceDebugStressVisibleLayout()

                var nextPending: [DebugStressTerminalLoadTarget] = []
                nextPending.reserveCapacity(pendingTargets.count)
                var restartedThisPass = 0

                for (targetIndex, target) in pendingTargets.enumerated() {
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
                        hostedView.window != nil &&
                        hostedView.superview != nil

                    if shouldReconcileVisibleSelection {
                        target.workspace.scheduleDebugStressTerminalGeometryReconcile()
                        if pass == 1 || (pass % 4) == 0 {
                            if target.workspace.preloadTerminalPanelForDebugStress(
                                tabId: target.tabId,
                                inPane: target.paneId
                            ) != nil {
                                restartedThisPass += 1
                                attempts += 1
                            }
                        } else {
                            terminalPanel.requestViewReattach()
                            terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                        }
                    } else {
                        terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                    }
                    nextPending.append(target)

                    if ((targetIndex + 1) % 16) == 0 {
                        await Task.yield()
                    }
                }

                if nextPending.count != pendingTargets.count || restartedThisPass > 0 || pass == 1 || (pass % 8) == 0 {
                    dlog(
                        "stress.setup.await pass=\(pass) pending=\(nextPending.count) " +
                            "restarted=\(restartedThisPass)"
                    )
                }
                try? await Task.sleep(nanoseconds: debugStressSurfaceLoadPollNanoseconds)
                pendingTargets = nextPending
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

        private func logSlowShortcutMonitorLatencyIfNeeded(
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
            dlog(
                "stress.inputLag path=appMonitor ms=\(String(format: "%.2f", elapsedMs)) " +
                    "threshold=\(String(format: "%.2f", thresholdMs)) handled=\(handledByShortcut ? 1 : 0) " +
                    "plain=\(isPlainTyping ? 1 : 0) repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) " +
                    "mods=\(event.modifierFlags.rawValue) workspaces=\(snapshot.workspaceCount) " +
                    "terminals=\(snapshot.terminalPanelCount) surfacesReady=\(snapshot.loadedSurfaceCount) " +
                    "selected=\(snapshot.selectedWorkspace)"
            )
        }

        @objc func triggerSentryTestCrash(_: Any?) {
            SentrySDK.crash()
        }
    #endif

    // MARK: Computed Properties

    var updateViewModel: UpdateViewModel {
        updateController.viewModel
    }

    private var isRunningUnderXCTestCached: Bool {
        Self.cachedIsRunningUnderXCTest
    }

    // MARK: Lifecycle

    override init() {
        super.init()
        Self.shared = self
    }

    // MARK: Static Functions

    nonisolated static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        if let primary = resolvedWindowFrame(
            from: primarySnapshot?.frame,
            display: primarySnapshot?.display,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        return resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    nonisolated static func resolvedWindowFrame(
        from frameSnapshot: SessionRectSnapshot?,
        display displaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        guard let frameSnapshot else { return nil }
        let frame = frameSnapshot.cgRect
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite
        else {
            return nil
        }

        let minWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)
        let minHeight = CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        guard frame.width >= minWidth,
              frame.height >= minHeight
        else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = display(for: displaySnapshot, in: availableDisplays) {
            if shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    nonisolated static func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
        isTerminatingApp: Bool
    ) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSkipSessionSaveDuringStartupRestore(
        isApplyingStartupSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingStartupSessionRestore && !includeScrollback
    }

    nonisolated static func shouldRunSessionAutosaveTick(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldWriteSessionSnapshotSynchronously(
        isTerminatingApp: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isTerminatingApp && includeScrollback
    }

    nonisolated static func shouldSkipSessionAutosaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint
        else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
    }

    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: @MainActor (SettingsNavigationTarget?) -> Void = { target in
            SettingsWindowController.shared.show(navigationTarget: target)
        },
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    ) {
        #if DEBUG
            dlog("settings.open.present path=customWindowDirect")
        #endif
        showFallbackSettingsWindow(navigationTarget)
        activateApplication()
        if let window = SettingsWindowController.shared.window {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
        #if DEBUG
            dlog("settings.open.present activate=1")
        #endif
    }

    static func installWindowResponderSwizzlesForTesting() {
        _ = didInstallWindowKeyEquivalentSwizzle
        _ = didInstallWindowFirstResponderSwizzle
        _ = didInstallWindowSendEventSwizzle
    }

    #if DEBUG
        static func setWindowFirstResponderGuardTesting(currentEvent: NSEvent?, hitView: NSView?) {
            cmuxFirstResponderGuardCurrentEventOverride = currentEvent
            cmuxFirstResponderGuardHitViewOverride = hitView
        }

        static func clearWindowFirstResponderGuardTesting() {
            cmuxFirstResponderGuardCurrentEventOverride = nil
            cmuxFirstResponderGuardHitViewOverride = nil
        }
    #endif

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

    private nonisolated static func enqueueLaunchServicesRegistrationWork(_ work: @escaping @Sendable () -> Void) {
        launchServicesRegistrationQueue.async(execute: work)
    }

    private nonisolated static func encodedPersistedWindowGeometryData(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?
    ) -> Data? {
        guard let frame else { return nil }
        let payload = PersistedWindowGeometry(frame: frame, display: display)
        return try? JSONEncoder().encode(payload)
    }

    private nonisolated static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            return clampFrame(
                frame,
                within: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: targetDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func display(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID })
        {
            return exact
        }

        guard let referenceRect = (snapshot.visibleFrame ?? snapshot.frame)?.cgRect else {
            return nil
        }

        let overlaps = displays.map { display -> (display: SessionDisplayGeometry, area: CGFloat) in
            (display, intersectionArea(referenceRect, display.visibleFrame))
        }
        if let bestOverlap = overlaps.max(by: { $0.area < $1.area }), bestOverlap.area > 0 {
            return bestOverlap.display
        }

        let referenceCenter = CGPoint(x: referenceRect.midX, y: referenceRect.midY)
        return displays.min { lhs, rhs in
            let lhsDistance = distanceSquared(lhs.visibleFrame, referenceCenter)
            let rhsDistance = distanceSquared(rhs.visibleFrame, referenceCenter)
            return lhsDistance < rhsDistance
        }
    }

    private nonisolated static func remappedFrame(
        _ frame: CGRect,
        from sourceRect: CGRect,
        to targetRect: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let source = sourceRect.standardized
        let target = targetRect.standardized
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 1,
              source.height > 1,
              target.width.isFinite,
              target.height.isFinite,
              target.width > 0,
              target.height > 0
        else {
            return centeredFrame(frame, in: targetRect, minWidth: minWidth, minHeight: minHeight)
        }

        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let relativeWidth = frame.width / source.width
        let relativeHeight = frame.height / source.height

        let remapped = CGRect(
            x: target.minX + (relativeX * target.width),
            y: target.minY + (relativeY * target.height),
            width: target.width * relativeWidth,
            height: target.height * relativeHeight
        )
        return clampFrame(remapped, within: target, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func centeredFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2),
            width: frame.width,
            height: frame.height
        )
        return clampFrame(centered, within: visibleFrame, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func clampFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0
        else {
            return frame
        }

        let maxWidth = max(visibleFrame.width, 1)
        let maxHeight = max(visibleFrame.height, 1)
        let widthFloor = min(minWidth, maxWidth)
        let heightFloor = min(minHeight, maxHeight)

        let width = min(max(frame.width, widthFloor), maxWidth)
        let height = min(max(frame.height, heightFloor), maxHeight)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private nonisolated static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private nonisolated static func distanceSquared(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return (dx * dx) + (dy * dy)
    }

    private nonisolated static func shouldPreserveExactFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        guard let snapshotDisplayID = displaySnapshot.displayID,
              let targetDisplayID = targetDisplay.displayID,
              snapshotDisplayID == targetDisplayID
        else {
            return false
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.frame)
        } ?? false
        guard visibleMatches || frameMatches else { return false }

        return frame.width.isFinite
            && frame.height.isFinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
    }

    private nonisolated static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }

    private nonisolated static func hashFrame(_ frame: NSRect, into hasher: inout Hasher) {
        let standardized = frame.standardized
        let quantized = [
            standardized.origin.x,
            standardized.origin.y,
            standardized.size.width,
            standardized.size.height,
        ].map { Int(($0 * 2).rounded()) }
        quantized.forEach { hasher.combine($0) }
    }

    // MARK: Functions

    func applicationDidFinishLaunching(_: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)
        let telemetryEnabled = TelemetrySettings.enabledForCurrentLaunch

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemesReloadNotification(_:)),
            name: CmuxThemeNotifications.reloadConfig,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        #if DEBUG
            // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
            // key-equivalent routing flaky. Force defaults for deterministic tests.
            if isRunningUnderXCTest {
                KeyboardShortcutSettings.resetAll()
            }
        #endif

        #if DEBUG
            writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
            CmuxMainRunLoopStallMonitor.shared.installIfNeeded()
            CmuxMainThreadTurnProfiler.shared.installIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
            }
        #endif

        if telemetryEnabled {
            // Pre-warm locale before Sentry to avoid a startup data race.
            // Locale initialization (os.locale.ensureLocale / NSLocale._preferredLanguages)
            // on the main thread can race with Sentry's background init thread
            // calling posix.getenv, causing a SIGSEGV ~134ms after launch.
            // Forcing locale access here before SentrySDK.start eliminates the race.
            // Related to: #836
            _ = Locale.current
            _ = NSLocale.preferredLanguages

            SentrySDK.start { options in
                options.dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
                #if DEBUG
                    options.environment = "development"
                    options.debug = true
                #else
                    options.environment = "production"
                    options.debug = false
                #endif
                options.sendDefaultPii = false

                // Performance tracing (10% of transactions)
                options.tracesSampleRate = 0.1
                // Keep app-hang tracking enabled, but avoid reporting short main-thread stalls
                // as hangs in normal user interaction flows.
                options.appHangTimeoutInterval = 8.0
                // Attach stack traces to all events
                options.attachStacktrace = true
                // Avoid recursively capturing failed requests from Sentry's own ingestion endpoint.
                options.enableCaptureFailedRequests = false
            }
        }

        if telemetryEnabled, !isRunningUnderXCTest {
            PostHogAnalytics.shared.startIfNeeded()
        }

        let forceDuplicateLaunchObserver = env["CMUX_UI_TEST_ENABLE_DUPLICATE_LAUNCH_OBSERVER"] == "1"

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduleLaunchServicesBundleRegistration()
                enforceSingleInstance()
                observeDuplicateLaunches()
            }
        } else if forceDuplicateLaunchObserver {
            // Some UI regressions specifically exercise launch-observer behavior while still
            // running under XCTest. Allow an explicit opt-in for those cases only.
            DispatchQueue.main.async { [weak self] in
                self?.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        if !isRunningUnderXCTest {
            configureUserNotifications()
            installMenuBarVisibilityObserver()
            syncMenuBarExtraVisibility()
            // Sparkle updater is started lazily on first manual check. This avoids any
            // first-launch permission prompts and keeps cmux aligned with the update pill UI.
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        NSApp.servicesProvider = self
        #if DEBUG
            UpdateTestSupport.applyIfNeeded(to: updateController.viewModel)
            if env["CMUX_UI_TEST_MODE"] == "1" {
                let trigger = env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
                let feed = env["CMUX_UI_TEST_FEED_URL"] ?? "<nil>"
                UpdateLogStore.shared.append("ui test env: trigger=\(trigger) feed=\(feed)")
            }
            if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
                UpdateLogStore.shared.append("ui test trigger update check detected")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }
                    let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                    UpdateLogStore.shared.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                    if UpdateTestSupport.performMockFeedCheckIfNeeded(on: updateController.viewModel) {
                        return
                    }
                    checkForUpdates(nil)
                }
            }

            // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
            // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
            if isRunningUnderXCTest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }
                    if NSApp.windows.isEmpty {
                        openNewMainWindow(nil)
                    }
                    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                    writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
                }
            }
        #endif
    }

    func applicationDidBecomeActive(_: Notification) {
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0,
        ])
        if TelemetrySettings.enabledForCurrentLaunch, !isRunningUnderXCTestCached {
            PostHogAnalytics.shared.trackActive(reason: "didBecomeActive")
        }

        guard let notificationStore else { return }
        notificationStore.handleApplicationDidBecomeActive()
        guard let tabManager else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId })
        {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
        stopSessionAutosaveTimer()
        stopSocketListenerHealthMonitor()
        TerminalController.shared.stop()
        VSCodeServeWebController.shared.stop()
        BrowserHistoryStore.shared.flushPendingSaves()
        if TelemetrySettings.enabledForCurrentLaunch {
            PostHogAnalytics.shared.flush()
        }
        notificationStore?.clearAll()
        enableSuddenTerminationIfNeeded()
    }

    func applicationWillResignActive(_: Notification) {
        guard !isTerminatingApp else { return }
        _ = saveSessionSnapshot(includeScrollback: false)
    }

    func persistSessionForUpdateRelaunch() {
        isTerminatingApp = true
        _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        prepareStartupSessionSnapshotIfNeeded()
        startSessionAutosaveTimerIfNeeded()
        startSocketListenerHealthMonitorIfNeeded()
        #if DEBUG
            setupJumpUnreadUITestIfNeeded()
            setupGotoSplitUITestIfNeeded()
            setupMultiWindowNotificationsUITestIfNeeded()

            // UI tests sometimes don't run SwiftUI `.onAppear` soon enough (or at all) on the VM.
            // The automation socket is a core testing primitive, so ensure it's started here when
            // we detect XCTest, even if the main view lifecycle is flaky.
            let env = ProcessInfo.processInfo.environment
            if isRunningUnderXCTest(env) {
                let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
                    ?? SocketControlSettings.defaultMode.rawValue
                let userMode = SocketControlSettings.migrateMode(raw)
                let mode = SocketControlSettings.effectiveMode(userMode: userMode)
                if mode != .off {
                    TerminalController.shared.start(
                        tabManager: tabManager,
                        socketPath: SocketControlSettings.socketPath(),
                        accessMode: mode
                    )
                }
            }
        #endif
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState
    ) {
        tabManager.window = window

        let key = ObjectIdentifier(window)
        #if DEBUG
            let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        if let existing = mainWindowContexts[key] {
            existing.window = window
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            existing.window = window
            reindexMainWindowContextIfNeeded(existing, for: window)
        } else {
            mainWindowContexts[key] = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                window: window
            )
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                unregisterMainWindow(closing)
            }
        }
        commandPaletteVisibilityByWindowId[windowId] = false
        commandPaletteSelectionByWindowId[windowId] = 0
        commandPaletteSnapshotByWindowId[windowId] = .empty

        #if DEBUG
            dlog(
                "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
            )
        #endif
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if !isTerminatingApp {
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    func listMainWindowSummaries() -> [MainWindowSummary] {
        let contexts = Array(mainWindowContexts.values)
        return contexts.map { ctx in
            let window = ctx.window ?? windowForMainWindowId(ctx.windowId)
            return MainWindowSummary(
                windowId: ctx.windowId,
                isKeyWindow: window?.isKeyWindow ?? false,
                isVisible: window?.isVisible ?? false,
                workspaceCount: ctx.tabManager.tabs.count,
                selectedWorkspaceId: ctx.tabManager.selectedTabId
            )
        }
    }

    func windowMoveTargets(referenceWindowId: UUID?) -> [WindowMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)
        return orderedSummaries.compactMap { summary in
            guard let manager = tabManagerFor(windowId: summary.windowId) else { return nil }
            let label = labels[summary.windowId] ?? "Window"
            return WindowMoveTarget(
                windowId: summary.windowId,
                label: label,
                tabManager: manager,
                isCurrentWindow: summary.windowId == referenceWindowId
            )
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        var targets: [WorkspaceMoveTarget] = []
        targets.reserveCapacity(orderedSummaries.reduce(0) { partial, summary in
            partial + summary.workspaceCount
        })

        for summary in orderedSummaries {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            let windowLabel = labels[summary.windowId] ?? "Window"
            let isCurrentWindow = summary.windowId == referenceWindowId
            for workspace in manager.tabs {
                if workspace.id == excludingWorkspaceId {
                    continue
                }
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.id,
                        windowLabel: windowLabel,
                        workspaceTitle: workspaceDisplayName(workspace),
                        tabManager: manager,
                        isCurrentWindow: isCurrentWindow
                    )
                )
            }
        }

        return targets
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, focus: Bool = true) -> Bool {
        guard let sourceManager = tabManagerFor(tabId: workspaceId),
              let destinationManager = tabManagerFor(windowId: windowId)
        else {
            return false
        }

        if sourceManager === destinationManager {
            if focus {
                destinationManager.focusTab(workspaceId, suppressFlash: true)
                _ = focusMainWindow(windowId: windowId)
                TerminalController.shared.setActiveTabManager(destinationManager)
            }
            return true
        }

        guard let workspace = sourceManager.detachWorkspace(tabId: workspaceId) else { return false }
        destinationManager.attachWorkspace(workspace, select: focus)

        if focus {
            _ = focusMainWindow(windowId: windowId)
            TerminalController.shared.setActiveTabManager(destinationManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        let windowId = createMainWindow()
        guard let destinationManager = tabManagerFor(windowId: windowId) else { return nil }
        let bootstrapWorkspaceId = destinationManager.tabs.first?.id

        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = closeMainWindow(windowId: windowId)
            return nil
        }

        // Remove the bootstrap workspace from the new window once the moved workspace arrives.
        if let bootstrapWorkspaceId,
           bootstrapWorkspaceId != workspaceId,
           let bootstrapWorkspace = destinationManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           destinationManager.tabs.count > 1
        {
            destinationManager.closeWorkspace(bootstrapWorkspace)
        }
        return windowId
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (context.windowId, workspace.id, panelId, context.tabManager)
                }
            }
        }
        return nil
    }

    @discardableResult
    func moveSurface(
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        #if DEBUG
            let moveStart = ProcessInfo.processInfo.systemUptime
            let splitLabel = splitTarget.map { split in
                "\(split.orientation.rawValue):\(split.insertFirst ? 1 : 0)"
            } ?? "none"
            func elapsedMs(since start: TimeInterval) -> String {
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                return String(format: "%.2f", ms)
            }
            dlog(
                "surface.move.begin panel=\(panelId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
                    "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                    "split=\(splitLabel) focus=\(focus ? 1 : 0) focusWindow=\(focusWindow ? 1 : 0)"
            )
        #endif
        guard let source = locateSurface(surfaceId: panelId) else {
            #if DEBUG
                dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourcePanelNotFound elapsedMs=\(elapsedMs(since: moveStart))")
            #endif
            return false
        }
        guard let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
            #if DEBUG
                dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourceWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
            #endif
            return false
        }
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId) else {
            #if DEBUG
                dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationManagerMissing elapsedMs=\(elapsedMs(since: moveStart))")
            #endif
            return false
        }
        guard let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == targetWorkspaceId }) else {
            #if DEBUG
                dlog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
            #endif
            return false
        }
        #if DEBUG
            dlog(
                "surface.move.route panel=\(panelId.uuidString.prefix(5)) sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) " +
                    "sourceWin=\(source.windowId.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
                    "sameWorkspace=\(destinationWorkspace.id == sourceWorkspace.id ? 1 : 0)"
            )
        #endif

        let resolvedTargetPane = targetPane.flatMap { pane in
            destinationWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? destinationWorkspace.bonsplitController.focusedPaneId
            ?? destinationWorkspace.bonsplitController.allPaneIds.first

        guard let resolvedTargetPane else {
            #if DEBUG
                dlog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=targetPaneMissing " +
                        "destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                )
            #endif
            return false
        }

        if destinationWorkspace.id == sourceWorkspace.id {
            if let splitTarget {
                guard let sourceTabId = sourceWorkspace.surfaceIdFromPanelId(panelId),
                      sourceWorkspace.bonsplitController.splitPane(
                          resolvedTargetPane,
                          orientation: splitTarget.orientation,
                          movingTab: sourceTabId,
                          insertFirst: splitTarget.insertFirst
                      ) != nil
                else {
                    #if DEBUG
                        dlog(
                            "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sameWorkspaceSplitFailed " +
                                "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) split=\(splitLabel) " +
                                "elapsedMs=\(elapsedMs(since: moveStart))"
                        )
                    #endif
                    return false
                }
                if focus {
                    source.tabManager.focusTab(sourceWorkspace.id, surfaceId: panelId, suppressFlash: true)
                }
                #if DEBUG
                    dlog(
                        "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceSplit moved=1 " +
                            "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                    )
                #endif
                return true
            }

            let moved = sourceWorkspace.moveSurface(
                panelId: panelId,
                toPane: resolvedTargetPane,
                atIndex: targetIndex,
                focus: focus
            )
            #if DEBUG
                dlog(
                    "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceMove moved=\(moved ? 1 : 0) " +
                        "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                        "elapsedMs=\(elapsedMs(since: moveStart))"
                )
            #endif
            return moved
        }

        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
        #if DEBUG
            let detachStart = ProcessInfo.processInfo.systemUptime
        #endif

        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else {
            #if DEBUG
                dlog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=detachFailed " +
                        "elapsedMs=\(elapsedMs(since: moveStart))"
                )
            #endif
            return false
        }
        #if DEBUG
            let detachMs = elapsedMs(since: detachStart)
            let attachStart = ProcessInfo.processInfo.systemUptime
        #endif
        guard destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: resolvedTargetPane,
            atIndex: targetIndex,
            focus: focus
        ) != nil else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
            #if DEBUG
                dlog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=attachFailed " +
                        "detachMs=\(detachMs) elapsedMs=\(elapsedMs(since: moveStart))"
                )
            #endif
            return false
        }
        #if DEBUG
            let attachMs = elapsedMs(since: attachStart)
            var splitMs = "0.00"
        #endif

        if let splitTarget {
            #if DEBUG
                let splitStart = ProcessInfo.processInfo.systemUptime
            #endif
            guard let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId),
                  destinationWorkspace.bonsplitController.splitPane(
                      resolvedTargetPane,
                      orientation: splitTarget.orientation,
                      movingTab: movedTabId,
                      insertFirst: splitTarget.insertFirst
                  ) != nil
            else {
                if let detachedFromDestination = destinationWorkspace.detachSurface(panelId: panelId) {
                    rollbackDetachedSurface(
                        detachedFromDestination,
                        to: sourceWorkspace,
                        sourcePane: sourcePane,
                        sourceIndex: sourceIndex,
                        focus: focus
                    )
                }
                #if DEBUG
                    dlog(
                        "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=postAttachSplitFailed " +
                            "detachMs=\(detachMs) attachMs=\(attachMs) elapsedMs=\(elapsedMs(since: moveStart))"
                    )
                #endif
                return false
            }
            #if DEBUG
                splitMs = elapsedMs(since: splitStart)
            #endif
        }

        #if DEBUG
            let cleanupStart = ProcessInfo.processInfo.systemUptime
        #endif
        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )
        #if DEBUG
            let cleanupMs = elapsedMs(since: cleanupStart)
            let focusStart = ProcessInfo.processInfo.systemUptime
        #endif

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: destinationManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(targetWorkspaceId, surfaceId: panelId, suppressFlash: true)
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: targetWorkspaceId,
                    destinationPanelId: panelId,
                    destinationManager: destinationManager
                )
            }
        }
        #if DEBUG
            let focusMs = elapsedMs(since: focusStart)
            dlog(
                "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=crossWorkspace moved=1 " +
                    "sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
                    "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                    "split=\(splitLabel) detachMs=\(detachMs) attachMs=\(attachMs) splitMs=\(splitMs) " +
                    "cleanupMs=\(cleanupMs) focusMs=\(focusMs) elapsedMs=\(elapsedMs(since: moveStart))"
            )
        #endif

        return true
    }

    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        #if DEBUG
            let moveStart = ProcessInfo.processInfo.systemUptime
            func elapsedMs(since start: TimeInterval) -> String {
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                return String(format: "%.2f", ms)
            }
            dlog(
                "surface.moveBonsplit.begin tab=\(tabId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
                    "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil")"
            )
        #endif
        guard let located = locateBonsplitSurface(tabId: tabId) else {
            #if DEBUG
                dlog(
                    "surface.moveBonsplit.fail tab=\(tabId.uuidString.prefix(5)) reason=tabNotFound " +
                        "targetWs=\(targetWorkspaceId.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                )
            #endif
            return false
        }
        #if DEBUG
            dlog(
                "surface.moveBonsplit.located tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
                    "sourceWs=\(located.workspaceId.uuidString.prefix(5)) sourceWin=\(located.windowId.uuidString.prefix(5))"
            )
        #endif
        let moved = moveSurface(
            panelId: located.panelId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
        #if DEBUG
            dlog(
                "surface.moveBonsplit.end tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
                    "moved=\(moved ? 1 : 0) elapsedMs=\(elapsedMs(since: moveStart))"
            )
        #endif
        return moved
    }

    func tabManagerFor(windowId: UUID) -> TabManager? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
    }

    func windowId(for tabManager: TabManager) -> UUID? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })?.windowId
    }

    func mainWindow(for windowId: UUID) -> NSWindow? {
        windowForMainWindowId(windowId)
    }

    func mainWindowContainingWorkspace(_ workspaceId: UUID) -> NSWindow? {
        for context in mainWindowContexts.values where context.tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                return window
            }
        }
        return nil
    }

    func scriptableMainWindows() -> [ScriptableMainWindowState] {
        var results: [ScriptableMainWindowState] = []
        var seen: Set<UUID> = []

        for window in NSApp.orderedWindows {
            guard let context = contextForMainTerminalWindow(window, reindex: false) else { continue }
            guard seen.insert(context.windowId).inserted else { continue }
            results.append(
                ScriptableMainWindowState(
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId)
                )
            )
        }

        let remaining = mainWindowContexts.values
            .sorted { $0.windowId.uuidString < $1.windowId.uuidString }
            .filter { seen.insert($0.windowId).inserted }

        for context in remaining {
            results.append(
                ScriptableMainWindowState(
                    windowId: context.windowId,
                    tabManager: context.tabManager,
                    window: context.window ?? windowForMainWindowId(context.windowId)
                )
            )
        }

        return results
    }

    func scriptableMainWindow(windowId: UUID) -> ScriptableMainWindowState? {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else {
            return nil
        }
        return ScriptableMainWindowState(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    func scriptableMainWindowForTab(_ tabId: UUID) -> ScriptableMainWindowState? {
        guard let context = contextContainingTabId(tabId) else { return nil }
        return ScriptableMainWindowState(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window ?? windowForMainWindowId(context.windowId)
        )
    }

    @discardableResult
    func focusScriptableMainWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        guard let state = scriptableMainWindow(windowId: windowId),
              let window = state.window
        else {
            return false
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }
        return true
    }

    @discardableResult
    func addWorkspace(windowId: UUID, workingDirectory: String? = nil, bringToFront shouldBringToFront: Bool = false) -> UUID? {
        guard let state = scriptableMainWindow(windowId: windowId) else { return nil }
        if shouldBringToFront, let window = state.window {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = state.tabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: shouldBringToFront
        )
        return workspace.id
    }

    func requestCommandPaletteCommands(preferredWindow: NSWindow? = nil, source: String = "api.commandPalette") {
        postCommandPaletteRequest(
            name: .commandPaletteRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteSwitcher(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteSwitcher") {
        postCommandPaletteRequest(
            name: .commandPaletteSwitcherRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameTab(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteRenameTab") {
        postCommandPaletteRequest(
            name: .commandPaletteRenameTabRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func requestCommandPaletteRenameWorkspace(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteRenameWorkspace"
    ) {
        postCommandPaletteRequest(
            name: .commandPaletteRenameWorkspaceRequested,
            preferredWindow: preferredWindow,
            source: source,
            markPending: true
        )
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        let wasVisible = commandPaletteVisibilityByWindowId[windowId] ?? false
        commandPaletteVisibilityByWindowId[windowId] = visible
        // Opening (false -> true) always resolves pending-open.
        // Closing (true -> false) also clears stale pending state.
        // Ignore repeated false updates so a stale sync cannot erase an in-flight open request.
        if visible || wasVisible {
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
        }
        #if DEBUG
            if !visible,
               !wasVisible,
               commandPalettePendingOpenByWindowId[windowId] == true
            {
                dlog(
                    "palette.visibility.retainPending " +
                        "window={\(debugWindowToken(window))} visible=0 wasVisible=0 pending=1"
                )
            }
        #endif
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSelectionByWindowId[windowId] = max(0, index)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteSelectionByWindowId[windowId] ?? 0
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteSnapshotByWindowId[windowId] = snapshot
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteSnapshotByWindowId[windowId] ?? .empty
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPaletteVisibilityByWindowId[windowId] ?? false
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        return nil
    }

    /// Resolve the workspace that currently owns a panel/surface ID.
    /// Prefer the provided workspace when available, then fall back to global lookup.
    func workspaceContainingPanel(
        panelId: UUID,
        preferredWorkspaceId: UUID? = nil
    ) -> (workspace: Workspace, tabManager: TabManager)? {
        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId),
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil
        {
            return (workspace, manager)
        }

        if let located = locateSurface(surfaceId: panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
           workspace.panels[panelId] != nil
        {
            return (workspace, located.tabManager)
        }

        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId) ?? tabManager,
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil
        {
            return (workspace, manager)
        }

        if let manager = tabManager,
           let workspace = manager.tabs.first(where: { $0.panels[panelId] != nil })
        {
            return (workspace, manager)
        }

        return nil
    }

    func locateGhosttySurface(_ surface: ghostty_surface_t?) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        guard let surface else { return nil }
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (ctx.windowId, ws.id, panelId, ctx.tabManager)
                    }
                }
            }
        }
        return nil
    }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(source: String) {
        var refreshedCount = 0
        forEachTerminalPanel { terminalPanel in
            terminalPanel.hostedView.reconcileGeometryNow()
            terminalPanel.surface.forceRefresh(reason: "appDelegate.refreshAfterGhosttyConfigReload")
            refreshedCount += 1
        }
        #if DEBUG
            dlog("reload.config.surfaceRefresh source=\(source) count=\(refreshedCount)")
        #endif
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if TerminalController.shouldSuppressSocketCommandActivation() {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                window.orderFront(nil)
                setActiveMainWindow(window)
            }
            return true
        }
        bringToFront(window)
        return true
    }

    func closeMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        window.performClose(nil)
        return true
    }

    @discardableResult
    func closeWindowWithConfirmation(_ window: NSWindow) -> Bool {
        guard isMainTerminalWindow(window) else {
            window.performClose(nil)
            return true
        }
        guard confirmCloseMainWindow(window) else { return true }
        window.performClose(nil)
        return true
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow)
            {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(NSApp.keyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager })
            {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

        #if DEBUG
            let beforeManagerToken = debugManagerToken(tabManager)
            dlog(
                "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
            )
        #endif
        guard let context else { return tabManager }
        let alreadyActive =
            tabManager === context.tabManager
                && sidebarState === context.sidebarState
                && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive {
            #if DEBUG
                dlog(
                    "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} nochange=1 \(debugShortcutRouteSnapshot())"
                )
            #endif
            return context.tabManager
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
        #if DEBUG
            dlog(
                "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
            )
        #endif
        return context.tabManager
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow() -> Bool {
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager })
        {
            if let window = activeContext.window ?? windowForMainWindowId(activeContext.windowId) {
                setActiveMainWindow(window)
            }
            activeContext.sidebarState.toggle()
            return true
        }
        if let keyContext = contextForMainWindow(NSApp.keyWindow) {
            if let window = keyContext.window ?? windowForMainWindowId(keyContext.windowId) {
                setActiveMainWindow(window)
            }
            keyContext.sidebarState.toggle()
            return true
        }
        if let mainContext = contextForMainWindow(NSApp.mainWindow) {
            if let window = mainContext.window ?? windowForMainWindowId(mainContext.windowId) {
                setActiveMainWindow(window)
            }
            mainContext.sidebarState.toggle()
            return true
        }
        if let fallbackContext = mainWindowContexts.values.first {
            if let window = fallbackContext.window ?? windowForMainWindowId(fallbackContext.windowId) {
                setActiveMainWindow(window)
            }
            fallbackContext.sidebarState.toggle()
            return true
        }
        if let sidebarState {
            sidebarState.toggle()
            return true
        }
        return false
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

    @objc func openNewMainWindow(_: Any?) {
        _ = createMainWindow()
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    @discardableResult
    func addWorkspaceInPreferredMainWindow(
        workingDirectory: String? = nil,
        shouldBringToFront: Bool = false,
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> UUID? {
        #if DEBUG
            logWorkspaceCreationRouting(
                phase: "request",
                source: debugSource,
                reason: "add_workspace",
                event: event,
                chosenContext: nil,
                workingDirectory: workingDirectory
            )
        #endif
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "no_context",
                    source: debugSource,
                    reason: "context_selection_failed",
                    event: event,
                    chosenContext: nil,
                    workingDirectory: workingDirectory
                )
            #endif
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "no_context",
                    source: debugSource,
                    reason: "context_window_missing",
                    event: event,
                    chosenContext: context,
                    workingDirectory: workingDirectory
                )
            #endif
            discardOrphanedMainWindowContext(context)
            return nil
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }

        let workspace: Workspace = if let workingDirectory {
            context.tabManager.addWorkspace(workingDirectory: workingDirectory, select: true)
        } else {
            context.tabManager.addTab(select: true)
        }
        #if DEBUG
            logWorkspaceCreationRouting(
                phase: "created",
                source: debugSource,
                reason: "workspace_created",
                event: event,
                chosenContext: context,
                workspaceId: workspace.id,
                workingDirectory: workingDirectory
            )
        #endif
        return workspace.id
    }

    @discardableResult
    func createMainWindow(
        initialWorkingDirectory: String? = nil,
        sessionWindowSnapshot: SessionWindowSnapshot? = nil
    ) -> UUID {
        let windowId = UUID()
        let tabManager = TabManager(initialWorkingDirectory: initialWorkingDirectory)
        if let tabManagerSnapshot = sessionWindowSnapshot?.tabManager {
            tabManager.restoreSessionSnapshot(tabManagerSnapshot)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar
            .width
            .map(SessionPersistencePolicy.sanitizedSidebarWidth)
            ?? SessionPersistencePolicy.defaultSidebarWidth
        let sidebarState = SidebarState(
            isVisible: sessionWindowSnapshot?.sidebar.isVisible ?? true,
            persistedWidth: CGFloat(sidebarWidth)
        )
        let sidebarSelectionState = SidebarSelectionState(
            selection: sessionWindowSnapshot?.sidebar.selection.sidebarSelection ?? .tabs
        )
        let notificationStore = TerminalNotificationStore.shared

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = false
        let restoredFrame = resolvedWindowFrame(from: sessionWindowSnapshot)
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
        }
        window.contentView = NSHostingView(rootView: root)

        // Apply shared window styling.
        attachUpdateAccessory(to: window)
        applyWindowDecorations(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            mainWindowControllers.removeAll(where: { $0 === controller })
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState
        )
        installFileDropOverlay(on: window, tabManager: tabManager)
        if TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            setActiveMainWindow(window)
            NSApp.activate(ignoringOtherApps: true)
        }
        if let restoredFrame {
            window.setFrame(restoredFrame, display: true)
            #if DEBUG
                dlog(
                    "session.restore.frameApplied window=\(windowId.uuidString.prefix(8)) " +
                        "applied={\(debugNSRectDescription(window.frame))}"
                )
            #endif
        }
        return windowId
    }

    @objc func checkForUpdates(_: Any?) {
        updateViewModel.overrideState = nil
        updateController.checkForUpdates()
    }

    func openWelcomeWorkspace() {
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else {
            return
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        sendWelcomeCommandWhenReady(to: workspace)
    }

    func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
        sendTextWhenReady("cmux welcome\n", to: workspace) {
            if markShownOnSend {
                UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
            }
        }
    }

    @objc func applyUpdateIfAvailable(_: Any?) {
        updateViewModel.overrideState = nil
        updateController.installUpdate()
    }

    @objc func attemptUpdate(_: Any?) {
        updateViewModel.overrideState = nil
        updateController.attemptUpdate()
    }

    func isCmuxCLIInstalledInPATH() -> Bool {
        CmuxCLIPathInstaller().isInstalled()
    }

    @objc func installCmuxCLIInPath(_: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.install()
            var informativeText = String(localized: "cli.install.symlinkCreated", defaultValue: "Created symlink:\n\n\(outcome.destinationURL.path) -> \(outcome.sourceURL.path)")
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.install.adminRequired", defaultValue: "Administrator privileges were required to write to /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.installed", defaultValue: "cmux CLI Installed"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.installFailed", defaultValue: "Couldn't Install cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc func uninstallCmuxCLIInPath(_: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.uninstall()
            let prefix = outcome.removedExistingEntry
                ? String(localized: "cli.uninstall.removed", defaultValue: "Removed \(outcome.destinationURL.path).")
                : String(localized: "cli.uninstall.notFound", defaultValue: "No cmux CLI symlink was found at \(outcome.destinationURL.path).")
            var informativeText = prefix
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.uninstall.adminRequired", defaultValue: "Administrator privileges were required to modify /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.uninstalled", defaultValue: "cmux CLI Uninstalled"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc func restartSocketListener(_: Any?) {
        guard tabManager != nil else {
            NSSound.beep()
            return
        }

        guard socketListenerConfigurationIfEnabled() != nil else {
            TerminalController.shared.stop()
            NSSound.beep()
            return
        }
        restartSocketListenerIfEnabled(source: "menu.command")
    }

    @MainActor
    func openPreferencesWindow(debugSource: String, navigationTarget: SettingsNavigationTarget? = nil) {
        #if DEBUG
            dlog("settings.open.request source=\(debugSource)")
        #endif
        Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraController?.refreshForDebugControls()
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow)
            {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId)
        {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
        @objc func showUpdatePill(_: Any?) {
            updateViewModel.debugOverrideText = nil
            updateViewModel.overrideState = .installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {}))
        }

        @objc func showUpdatePillLongNightly(_: Any?) {
            updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
            updateViewModel.overrideState = .notFound(.init(acknowledgement: {}))
        }

        @objc func showUpdatePillLoading(_: Any?) {
            updateViewModel.debugOverrideText = nil
            updateViewModel.overrideState = .checking(.init(cancel: {}))
        }

        @objc func hideUpdatePill(_: Any?) {
            updateViewModel.debugOverrideText = nil
            updateViewModel.overrideState = .idle
        }

        @objc func clearUpdatePillOverride(_: Any?) {
            updateViewModel.debugOverrideText = nil
            updateViewModel.overrideState = nil
        }
    #endif

    @objc func copyUpdateLogs(_: Any?) {
        let logText = UpdateLogStore.shared.snapshot()
        let payload: String = if logText.isEmpty {
            "No update logs captured.\nLog file: \(UpdateLogStore.shared.logPath())"
        } else {
            logText + "\nLog file: \(UpdateLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    @objc func copyFocusLogs(_: Any?) {
        let logText = FocusLogStore.shared.snapshot()
        let payload: String = if logText.isEmpty {
            "No focus logs captured.\nLog file: \(FocusLogStore.shared.logPath())"
        } else {
            logText + "\nLog file: \(FocusLogStore.shared.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        titlebarAccessoryController.dismissNotificationsPopoverIfShown()
    }

    func jumpToLatestUnread() {
        guard let notificationStore else { return }
        #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData([
                    "jumpUnreadInvoked": "1",
                    "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
                ])
            }
        #endif
        // Prefer the latest unread that we can actually open. In early startup (especially on the VM),
        // the window-context registry can lag behind model initialization, so fall back to whatever
        // tab manager currently owns the tab.
        for notification in notificationStore.notifications where !notification.isRead {
            if openNotification(tabId: notification.tabId, surfaceId: notification.surfaceId, notificationId: notification.id) {
                return
            }
        }
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId })
        else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "dialog.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "dialog.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    @discardableResult
    func openBrowserAndFocusAddressBar(url: URL? = nil, insertAtEnd: Bool = false) -> UUID? {
        guard let panelId = tabManager?.openBrowser(url: url, insertAtEnd: insertAtEnd) else {
            #if DEBUG
                dlog(
                    "browser.focus.openAndFocus result=open_failed insertAtEnd=\(insertAtEnd ? 1 : 0) " +
                        "url=\(redactedDebugURL(url)) \(browserFocusStateSnapshot())"
                )
            #endif
            return nil
        }
        #if DEBUG
            dlog(
                "browser.focus.openAndFocus result=open_ok panel=\(panelId.uuidString.prefix(5)) " +
                    "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
            )
        #endif
        #if DEBUG
            let didFocus = focusBrowserAddressBar(panelId: panelId)
            dlog(
                "browser.focus.openAndFocus result=focus_request panel=\(panelId.uuidString.prefix(5)) " +
                    "focused=\(didFocus ? 1 : 0) \(browserFocusStateSnapshot())"
            )
        #else
            _ = focusBrowserAddressBar(panelId: panelId)
        #endif
        return panelId
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserAddressBarFocusedPanelId
    }

    @discardableResult
    func requestBrowserAddressBarFocus(panelId: UUID) -> Bool {
        focusBrowserAddressBar(panelId: panelId)
    }

    @discardableResult
    func performSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        let directionLabel = switch direction {
            case .left: "left"
            case .right: "right"
            case .up: "up"
            case .down: "down"
        }

        #if DEBUG
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow: Int = {
                if let v = firstResponder as? NSView {
                    return v.window?.windowNumber ?? -1
                }
                if let w = firstResponder as? NSWindow {
                    return w.windowNumber
                }
                return -1
            }()
            let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
            if let browser = tabManager?.focusedBrowserPanel {
                let webWindow = browser.webView.window?.windowNumber ?? -1
                let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                dlog("split.shortcut dir=\(directionLabel) pre panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
            } else {
                dlog("split.shortcut dir=\(directionLabel) pre panel=nil \(splitContext)")
            }
        #endif

        prepareFocusedBrowserDevToolsForSplit(directionLabel: directionLabel)
        tabManager?.createSplit(direction: direction)
        #if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                let keyWindow = NSApp.keyWindow
                let firstResponder = keyWindow?.firstResponder
                let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                let firstResponderWindow: Int = {
                    if let v = firstResponder as? NSView {
                        return v.window?.windowNumber ?? -1
                    }
                    if let w = firstResponder as? NSWindow {
                        return w.windowNumber
                    }
                    return -1
                }()
                let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
                if let browser = self?.tabManager?.focusedBrowserPanel {
                    let webWindow = browser.webView.window?.windowNumber ?? -1
                    let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                    dlog("split.shortcut dir=\(directionLabel) post panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
                } else {
                    dlog("split.shortcut dir=\(directionLabel) post panel=nil \(splitContext)")
                }
            }
            recordGotoSplitSplitIfNeeded(direction: direction)
        #endif
        return true
    }

    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        #if DEBUG
            let directionLabel = switch direction {
                case .left: "left"
                case .right: "right"
                case .up: "up"
                case .down: "down"
            }
            let selectedTabBefore = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focusedPanelBefore = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            dlog(
                "split.browser.shortcut pre dir=\(directionLabel) " +
                    "tab=\(selectedTabBefore) focusedPanel=\(focusedPanelBefore)"
            )
        #endif

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else {
            #if DEBUG
                dlog("split.browser.shortcut failed dir=\(directionLabel)")
            #endif
            return false
        }

        #if DEBUG
            let selectedTabAfter = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focusedPanelAfter = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            dlog(
                "split.browser.shortcut post dir=\(directionLabel) " +
                    "created=\(panelId.uuidString.prefix(5)) tab=\(selectedTabAfter) focusedPanel=\(focusedPanelAfter)"
            )
        #endif

        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    @discardableResult
    func requestRenameWorkspaceViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteRenameWorkspace(
            preferredWindow: targetWindow,
            source: "shortcut.renameWorkspace"
        )
        return true
    }

    #if DEBUG
        /// Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
        /// logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
        /// synthetic NSEvents.
        func debugHandleCustomShortcut(event: NSEvent) -> Bool {
            handleCustomShortcut(event: event)
        }

        /// Debug/test hook: mirrors local monitor routing (keyDown + keyUp lifecycle).
        func debugHandleShortcutMonitorEvent(event: NSEvent) -> Bool {
            if event.type == .keyDown {
                return handleCustomShortcut(event: event)
            }
            handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            return clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true)
        }

        func debugMarkCommandPaletteOpenPending(window: NSWindow) {
            markCommandPaletteOpenRequested(for: window)
        }

        @discardableResult
        func debugSetCommandPalettePendingOpenAge(window: NSWindow, age: TimeInterval) -> Bool {
            guard let windowId = mainWindowId(for: window) else { return false }
            commandPalettePendingOpenByWindowId[windowId] = true
            commandPaletteRecentRequestAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime - max(age, 0)
            return true
        }

        /// Test hook: remap a window context under a detached window key so direct
        /// ObjectIdentifier(window) lookups fail and fallback logic is exercised.
        @discardableResult
        func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
            guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
                  let window = context.window ?? windowForMainWindowId(windowId)
            else {
                return false
            }

            let detachedWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            debugDetachedContextWindows.append(detachedWindow)

            let contextKeys = mainWindowContexts.compactMap { key, value in
                value === context ? key : nil
            }
            for key in contextKeys {
                mainWindowContexts.removeValue(forKey: key)
            }
            mainWindowContexts[ObjectIdentifier(detachedWindow)] = context
            context.window = window
            return true
        }
    #endif

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updateController.validateMenuItem(item)
    }

    #if DEBUG
        func scheduleLaunchServicesBundleRegistrationForTesting(
            bundleURL: URL,
            scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
            register: @escaping (CFURL) -> OSStatus,
            breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
        ) {
            scheduleLaunchServicesBundleRegistration(
                bundleURL: bundleURL,
                scheduler: scheduler,
                register: register,
                breadcrumb: breadcrumb
            )
        }
    #endif

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil {
            options.insert(.sound)
        }
        completionHandler(options)
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        contextContainingTabId(tabId)?.tabManager
    }

    func closeMainWindowContainingTabId(_ tabId: UUID) {
        guard let context = contextContainingTabId(tabId) else { return }
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        window?.performClose(nil)
    }

    @discardableResult
    func openNotification(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        #if DEBUG
            let isJumpUnreadUITest = ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1"
            if isJumpUnreadUITest {
                writeJumpUnreadTestData([
                    "jumpUnreadOpenCalled": "1",
                    "jumpUnreadOpenTabId": tabId.uuidString,
                    "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
                ])
            }
        #endif
        guard let context = contextContainingTabId(tabId) else {
            #if DEBUG
                recordMultiWindowNotificationOpenFailureIfNeeded(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    notificationId: notificationId,
                    reason: "missing_context"
                )
            #endif
            #if DEBUG
                if isJumpUnreadUITest {
                    writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "0", "jumpUnreadOpenUsedFallback": "1"])
                }
            #endif
            let ok = openNotificationFallback(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
            #if DEBUG
                if isJumpUnreadUITest {
                    writeJumpUnreadTestData(["jumpUnreadOpenResult": ok ? "1" : "0"])
                }
            #endif
            return ok
        }
        #if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "1", "jumpUnreadOpenUsedFallback": "0"])
            }
        #endif
        return openNotificationInContext(context, tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    func tabTitle(for tabId: UUID) -> String? {
        if let context = contextContainingTabId(tabId) {
            return context.tabManager.tabs.first(where: { $0.id == tabId })?.title
        }
        return tabManager?.tabs.first(where: { $0.id == tabId })?.title
    }

    func recordTypingActivity() {
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }

    private func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        Self.detectRunningUnderXCTest(env)
    }

    #if DEBUG
        private func pointerString(_ object: AnyObject?) -> String {
            guard let object else { return "nil" }
            return String(describing: Unmanaged.passUnretained(object).toOpaque())
        }

        private func summarizeContextForWorkspaceRouting(_ context: MainWindowContext?) -> String {
            guard let context else { return "nil" }
            let window = context.window ?? windowForMainWindowId(context.windowId)
            let windowNumber = window?.windowNumber ?? -1
            let key = window?.isKeyWindow == true ? 1 : 0
            let main = window?.isMainWindow == true ? 1 : 0
            let visible = window?.isVisible == true ? 1 : 0
            let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
            return "wid=\(context.windowId.uuidString.prefix(8)) win=\(windowNumber) key=\(key) main=\(main) vis=\(visible) tabs=\(context.tabManager.tabs.count) sel=\(selected) tm=\(pointerString(context.tabManager))"
        }

        private func summarizeAllContextsForWorkspaceRouting() -> String {
            guard !mainWindowContexts.isEmpty else { return "<none>" }
            return mainWindowContexts.values
                .map { summarizeContextForWorkspaceRouting($0) }
                .joined(separator: " | ")
        }

        private func logWorkspaceCreationRouting(
            phase: String,
            source: String,
            reason: String,
            event: NSEvent?,
            chosenContext: MainWindowContext?,
            workspaceId: UUID? = nil,
            workingDirectory: String? = nil
        ) {
            let eventWindowNumber = event?.window?.windowNumber ?? -1
            let eventNumber = event?.windowNumber ?? -1
            let eventChars = event?.charactersIgnoringModifiers ?? ""
            let eventKeyCode = event.map { String($0.keyCode) } ?? "nil"
            let keyWindowNumber = NSApp.keyWindow?.windowNumber ?? -1
            let mainWindowNumber = NSApp.mainWindow?.windowNumber ?? -1
            let ws = workspaceId.map { String($0.uuidString.prefix(8)) } ?? "nil"
            let wd = workingDirectory.map { String($0.prefix(120)) } ?? "-"
            FocusLogStore.shared.append(
                "cmdn.route phase=\(phase) src=\(source) reason=\(reason) eventWin=\(eventWindowNumber) eventNum=\(eventNumber) keyCode=\(eventKeyCode) chars=\(eventChars) keyWin=\(keyWindowNumber) mainWin=\(mainWindowNumber) activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(chosenContext))} ws=\(ws) wd=\(wd) contexts=[\(summarizeAllContextsForWorkspaceRouting())]"
            )
        }
    #endif

    #if DEBUG
        private func writeUITestDiagnosticsIfNeeded(stage: String) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

            var payload = loadUITestDiagnostics(at: path)
            let isRunningUnderXCTest = isRunningUnderXCTest(env)

            let windows = NSApp.windows
            let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
            let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")

            payload["stage"] = stage
            payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
            payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
            payload["windowsCount"] = String(windows.count)
            payload["windowIdentifiers"] = ids
            payload["windowVisibleFlags"] = vis

            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func loadUITestDiagnostics(at path: String) -> [String: String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                return [:]
            }
            return object
        }
    #endif

    private func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        guard SessionRestorePolicy.shouldAttemptRestore() else { return }
        startupSessionSnapshot = SessionPersistenceStore.load()
    }

    private func persistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) -> PersistedWindowGeometry? {
        guard let data = defaults.data(forKey: Self.persistedWindowGeometryDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedWindowGeometry.self, from: data)
    }

    private func persistWindowGeometry(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?,
        defaults: UserDefaults = .standard
    ) {
        guard let data = Self.encodedPersistedWindowGeometryData(frame: frame, display: display) else {
            return
        }
        defaults.set(data, forKey: Self.persistedWindowGeometryDefaultsKey)
    }

    private func persistWindowGeometry(from window: NSWindow?) {
        guard let window else { return }
        persistWindowGeometry(
            frame: SessionRectSnapshot(window.frame),
            display: displaySnapshot(for: window)
        )
    }

    private func currentDisplayGeometries() -> (
        available: [SessionDisplayGeometry],
        fallback: SessionDisplayGeometry?
    ) {
        let available = NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        let fallback = (NSScreen.main ?? NSScreen.screens.first).map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return (available, fallback)
    }

    private func attemptStartupSessionRestoreIfNeeded(primaryWindow: NSWindow) {
        guard !didAttemptStartupSessionRestore else { return }
        didAttemptStartupSessionRestore = true
        guard !didHandleExplicitOpenIntentAtStartup else { return }
        guard let primaryContext = contextForMainTerminalWindow(primaryWindow) else { return }

        let startupSnapshot = startupSessionSnapshot
        let primaryWindowSnapshot = startupSnapshot?.windows.first
        if let primaryWindowSnapshot {
            isApplyingStartupSessionRestore = true
            #if DEBUG
                dlog(
                    "session.restore.start windows=\(startupSnapshot?.windows.count ?? 0) " +
                        "primaryFrame={\(debugSessionRectDescription(primaryWindowSnapshot.frame))} " +
                        "primaryDisplay={\(debugSessionDisplayDescription(primaryWindowSnapshot.display))}"
                )
            #endif
            applySessionWindowSnapshot(
                primaryWindowSnapshot,
                to: primaryContext,
                window: primaryWindow
            )
        } else {
            let displays = currentDisplayGeometries()
            let fallbackGeometry = persistedWindowGeometry()
            if let restoredFrame = Self.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: nil,
                fallbackFrame: fallbackGeometry?.frame,
                fallbackDisplaySnapshot: fallbackGeometry?.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) {
                primaryWindow.setFrame(restoredFrame, display: true)
            }
        }

        if let startupSnapshot {
            let additionalWindows = Array(startupSnapshot
                .windows
                .dropFirst()
                .prefix(max(0, SessionPersistencePolicy.maxWindowsPerSnapshot - 1)))
            #if DEBUG
                for (index, windowSnapshot) in additionalWindows.enumerated() {
                    dlog(
                        "session.restore.enqueueAdditional idx=\(index + 1) " +
                            "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                            "display={\(debugSessionDisplayDescription(windowSnapshot.display))}"
                    )
                }
            #endif
            if !additionalWindows.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    for windowSnapshot in additionalWindows {
                        _ = createMainWindow(sessionWindowSnapshot: windowSnapshot)
                    }
                    completeStartupSessionRestore()
                }
            } else {
                completeStartupSessionRestore()
            }
        }
    }

    private func completeStartupSessionRestore() {
        startupSessionSnapshot = nil
        isApplyingStartupSessionRestore = false
        _ = saveSessionSnapshot(includeScrollback: false)
    }

    private func applySessionWindowSnapshot(
        _ snapshot: SessionWindowSnapshot,
        to context: MainWindowContext,
        window: NSWindow?
    ) {
        #if DEBUG
            dlog(
                "session.restore.apply window=\(context.windowId.uuidString.prefix(8)) " +
                    "liveWin=\(window?.windowNumber ?? -1) " +
                    "snapshotFrame={\(debugSessionRectDescription(snapshot.frame))} " +
                    "snapshotDisplay={\(debugSessionDisplayDescription(snapshot.display))}"
            )
        #endif
        context.tabManager.restoreSessionSnapshot(snapshot.tabManager)
        context.sidebarState.isVisible = snapshot.sidebar.isVisible
        context.sidebarState.persistedWidth = CGFloat(
            SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
        )
        context.sidebarSelectionState.selection = snapshot.sidebar.selection.sidebarSelection

        if let restoredFrame = resolvedWindowFrame(from: snapshot), let window {
            window.setFrame(restoredFrame, display: true)
            #if DEBUG
                dlog(
                    "session.restore.frameApplied window=\(context.windowId.uuidString.prefix(8)) " +
                        "applied={\(debugNSRectDescription(window.frame))}"
                )
            #endif
        }
    }

    private func resolvedWindowFrame(from snapshot: SessionWindowSnapshot?) -> NSRect? {
        let displays = currentDisplayGeometries()
        return Self.resolvedWindowFrame(
            from: snapshot?.frame,
            display: snapshot?.display,
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }

    private func displaySnapshot(for window: NSWindow?) -> SessionDisplaySnapshot? {
        guard let window else { return nil }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        guard let screen else { return nil }

        return SessionDisplaySnapshot(
            displayID: screen.cmuxDisplayID,
            frame: SessionRectSnapshot(screen.frame),
            visibleFrame: SessionRectSnapshot(screen.visibleFrame)
        )
    }

    private func startSessionAutosaveTimerIfNeeded() {
        guard sessionAutosaveTimer == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard !isRunningUnderXCTest(env) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  Self.shouldRunSessionAutosaveTick(isTerminatingApp: self.isTerminatingApp)
            else {
                return
            }
            runSessionAutosaveTick(source: "timer")
        }
        sessionAutosaveTimer = timer
        timer.resume()
    }

    private func stopSessionAutosaveTimer() {
        sessionAutosaveTimer?.cancel()
        sessionAutosaveTimer = nil
        sessionAutosaveTickInFlight = false
        sessionAutosaveDeferredRetryPending = false
    }

    private func installLifecycleSnapshotObserversIfNeeded() {
        guard !didInstallLifecycleSnapshotObservers else { return }
        didInstallLifecycleSnapshotObservers = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let powerOffObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isTerminatingApp = true
                _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
            }
        }
        lifecycleSnapshotObservers.append(powerOffObserver)

        let sessionResignObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isTerminatingApp {
                    _ = saveSessionSnapshot(includeScrollback: true, removeWhenEmpty: false)
                } else {
                    _ = saveSessionSnapshot(includeScrollback: false)
                }
            }
        }
        lifecycleSnapshotObservers.append(sessionResignObserver)

        let didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartSocketListenerIfEnabled(source: "workspace.didWake")
            }
        }
        lifecycleSnapshotObservers.append(didWakeObserver)
    }

    private func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {
        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else { return nil }
        return (mode: mode, path: SocketControlSettings.socketPath())
    }

    private func restartSocketListenerIfEnabled(source: String) {
        guard let tabManager,
              let config = socketListenerConfigurationIfEnabled() else { return }
        let restartPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": restartPath,
            "source": source,
        ])
        TerminalController.shared.stop()
        TerminalController.shared.start(tabManager: tabManager, socketPath: restartPath, accessMode: config.mode)
    }

    private func startSocketListenerHealthMonitorIfNeeded() {
        guard socketListenerHealthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.socketListenerHealthCheckInterval,
            repeating: Self.socketListenerHealthCheckInterval
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.restartSocketListenerIfNeededForHealthCheck(source: "health.timer")
            }
        }
        timer.resume()
        socketListenerHealthTimer = timer
    }

    private func stopSocketListenerHealthMonitor() {
        socketListenerHealthTimer?.cancel()
        socketListenerHealthTimer = nil
        socketListenerHealthCheckInFlight = false
    }

    private func restartSocketListenerIfNeededForHealthCheck(source: String) {
        guard !socketListenerHealthCheckInFlight,
              let config = socketListenerConfigurationIfEnabled() else { return }
        let terminalController = TerminalController.shared
        let expectedSocketPath = terminalController.activeSocketPath(preferredPath: config.path)
        socketListenerHealthCheckInFlight = true
        Thread.detachNewThread { [weak self, expectedSocketPath, source, terminalController] in
            let health = terminalController.socketListenerHealth(expectedSocketPath: expectedSocketPath)
            Task { @MainActor [weak self, health] in
                guard let self else { return }
                socketListenerHealthCheckInFlight = false
                handleSocketListenerHealthCheckResult(
                    health,
                    source: source,
                    expectedSocketPath: expectedSocketPath
                )
            }
        }
    }

    private func handleSocketListenerHealthCheckResult(
        _ health: TerminalController.SocketListenerHealth,
        source: String,
        expectedSocketPath: String
    ) {
        guard let config = socketListenerConfigurationIfEnabled() else { return }
        let currentExpectedSocketPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        guard currentExpectedSocketPath == expectedSocketPath else { return }
        guard !health.isHealthy else {
            lastSocketListenerUnhealthyCaptureAt = .distantPast
            return
        }
        let failureSignals = health.failureSignals
        var data: [String: Any] = [
            "source": source,
            "path": currentExpectedSocketPath,
            "isRunning": health.isRunning ? 1 : 0,
            "acceptLoopAlive": health.acceptLoopAlive ? 1 : 0,
            "socketPathMatches": health.socketPathMatches ? 1 : 0,
            "socketPathExists": health.socketPathExists ? 1 : 0,
            "socketProbePerformed": health.socketProbePerformed ? 1 : 0,
            "failureSignals": failureSignals,
        ]
        if let socketConnectable = health.socketConnectable {
            data["socketConnectable"] = socketConnectable ? 1 : 0
        }
        if let socketConnectErrno = health.socketConnectErrno {
            data["socketConnectErrno"] = Int(socketConnectErrno)
        }
        sentryBreadcrumb("socket.listener.unhealthy", category: "socket", data: data)
        let now = Date()
        if now.timeIntervalSince(lastSocketListenerUnhealthyCaptureAt) >= Self.socketListenerUnhealthyCaptureCooldown {
            lastSocketListenerUnhealthyCaptureAt = now
            sentryCaptureWarning(
                "socket.listener.unhealthy",
                category: "socket",
                data: data,
                contextKey: "socket_listener_health"
            )
        }
        restartSocketListenerIfEnabled(source: source)
    }

    private func disableSuddenTerminationIfNeeded() {
        guard !didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        didDisableSuddenTermination = true
    }

    private func enableSuddenTerminationIfNeeded() {
        guard didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        didDisableSuddenTermination = false
    }

    private func sessionAutosaveFingerprint(includeScrollback: Bool) -> Int? {
        guard !includeScrollback else { return nil }

        var hasher = Hasher()
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            lhs.windowId.uuidString < rhs.windowId.uuidString
        }
        hasher.combine(contexts.count)

        for context in contexts.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            hasher.combine(context.windowId)
            hasher.combine(context.tabManager.sessionAutosaveFingerprint())
            hasher.combine(context.sidebarState.isVisible)
            hasher.combine(
                Int(SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth)).rounded())
            )

            switch context.sidebarSelectionState.selection {
                case .tabs:
                    hasher.combine(0)
                case .notifications:
                    hasher.combine(1)
            }

            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                Self.hashFrame(window.frame, into: &hasher)
            } else {
                hasher.combine(-1)
            }
        }

        return hasher.finalize()
    }

    @discardableResult
    private func saveSessionSnapshot(includeScrollback: Bool, removeWhenEmpty: Bool = false) -> Bool {
        if Self.shouldSkipSessionSaveDuringStartupRestore(
            isApplyingStartupSessionRestore: isApplyingStartupSessionRestore,
            includeScrollback: includeScrollback
        ) {
            #if DEBUG
                dlog("session.save.skipped reason=startup_restore_in_progress includeScrollback=0")
            #endif
            return false
        }

        let writeSynchronously = Self.shouldWriteSessionSnapshotSynchronously(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: includeScrollback
        )
        #if DEBUG
            let timingStart = CmuxTypingTiming.start()
            defer {
                CmuxTypingTiming.logDuration(
                    path: "session.saveSnapshot",
                    startedAt: timingStart,
                    extra: "includeScrollback=\(includeScrollback ? 1 : 0) removeWhenEmpty=\(removeWhenEmpty ? 1 : 0) sync=\(writeSynchronously ? 1 : 0)"
                )
            }
        #endif

        guard let snapshot = buildSessionSnapshot(includeScrollback: includeScrollback) else {
            persistSessionSnapshot(
                nil,
                removeWhenEmpty: removeWhenEmpty,
                persistedGeometryData: nil,
                synchronously: writeSynchronously
            )
            return false
        }

        let persistedGeometryData = snapshot.windows.first.flatMap { primaryWindow in
            Self.encodedPersistedWindowGeometryData(
                frame: primaryWindow.frame,
                display: primaryWindow.display
            )
        }

        #if DEBUG
            debugLogSessionSaveSnapshot(snapshot, includeScrollback: includeScrollback)
        #endif
        persistSessionSnapshot(
            snapshot,
            removeWhenEmpty: false,
            persistedGeometryData: persistedGeometryData,
            synchronously: writeSynchronously
        )
        return true
    }

    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }

    private func scheduleDeferredSessionAutosaveRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard !sessionAutosaveDeferredRetryPending else { return }
        sessionAutosaveDeferredRetryPending = true
        sessionPersistenceQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                sessionAutosaveDeferredRetryPending = false
                runSessionAutosaveTick(source: "typingQuietRetry")
            }
        }
    }

    private func runSessionAutosaveTick(source: String) {
        guard Self.shouldRunSessionAutosaveTick(isTerminatingApp: isTerminatingApp) else { return }
        guard !sessionAutosaveTickInFlight else { return }
        if let remainingQuietPeriod = remainingSessionAutosaveTypingQuietPeriod() {
            #if DEBUG
                dlog(
                    "session.save.skipped reason=typing_recent includeScrollback=0 source=\(source) " +
                        "retryMs=\(Int((remainingQuietPeriod * 1000).rounded()))"
                )
            #endif
            scheduleDeferredSessionAutosaveRetry(after: remainingQuietPeriod)
            return
        }

        sessionAutosaveTickInFlight = true
        #if DEBUG
            let timingStart = CmuxTypingTiming.start()
            let phaseStart = ProcessInfo.processInfo.systemUptime
            var fingerprintMs: Double = 0
            var saveMs: Double = 0
            defer {
                sessionAutosaveTickInFlight = false
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "session.autosaveTick.phase",
                    totalMs: totalMs,
                    thresholdMs: 2.0,
                    parts: [
                        ("fingerprintMs", fingerprintMs),
                        ("saveMs", saveMs),
                    ],
                    extra: "source=\(source)"
                )
                CmuxTypingTiming.logDuration(
                    path: "session.autosaveTick",
                    startedAt: timingStart,
                    extra: "source=\(source)"
                )
            }
        #else
            defer { sessionAutosaveTickInFlight = false }
        #endif

        let now = Date()
        #if DEBUG
            let fingerprintStart = ProcessInfo.processInfo.systemUptime
        #endif
        let autosaveFingerprint = sessionAutosaveFingerprint(includeScrollback: false)
        #if DEBUG
            fingerprintMs = (ProcessInfo.processInfo.systemUptime - fingerprintStart) * 1000.0
        #endif
        if Self.shouldSkipSessionAutosaveForUnchangedFingerprint(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: false,
            previousFingerprint: lastSessionAutosaveFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastSessionAutosavePersistedAt,
            now: now
        ) {
            #if DEBUG
                dlog(
                    "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
                )
            #endif
            return
        }

        #if DEBUG
            let saveStart = ProcessInfo.processInfo.systemUptime
        #endif
        _ = saveSessionSnapshot(includeScrollback: false)
        #if DEBUG
            saveMs = (ProcessInfo.processInfo.systemUptime - saveStart) * 1000.0
        #endif
        updateSessionAutosaveSaveState(
            includeScrollback: false,
            persistedAt: now,
            fingerprint: autosaveFingerprint
        )
    }

    private func updateSessionAutosaveSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard !isTerminatingApp, !includeScrollback else { return }
        lastSessionAutosaveFingerprint = fingerprint
        lastSessionAutosavePersistedAt = persistedAt
    }

    private func persistSessionSnapshot(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool
    ) {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else { return }

        let writeBlock = {
            if let persistedGeometryData {
                UserDefaults.standard.set(
                    persistedGeometryData,
                    forKey: Self.persistedWindowGeometryDefaultsKey
                )
            }
            if let snapshot {
                _ = SessionPersistenceStore.save(snapshot)
            } else if removeWhenEmpty {
                SessionPersistenceStore.removeSnapshot()
            }
        }

        if synchronously {
            writeBlock()
        } else {
            sessionPersistenceQueue.async(execute: writeBlock)
        }
    }

    private func buildSessionSnapshot(includeScrollback: Bool) -> AppSessionSnapshot? {
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            let lhsWindow = lhs.window ?? windowForMainWindowId(lhs.windowId)
            let rhsWindow = rhs.window ?? windowForMainWindowId(rhs.windowId)
            let lhsIsKey = lhsWindow?.isKeyWindow ?? false
            let rhsIsKey = rhsWindow?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        guard !contexts.isEmpty else { return nil }

        let windows: [SessionWindowSnapshot] = contexts
            .prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
            .map { context in
                let window = context.window ?? windowForMainWindowId(context.windowId)
                return SessionWindowSnapshot(
                    frame: window.map { SessionRectSnapshot($0.frame) },
                    display: displaySnapshot(for: window),
                    tabManager: context.tabManager.sessionSnapshot(includeScrollback: includeScrollback),
                    sidebar: SessionSidebarSnapshot(
                        isVisible: context.sidebarState.isVisible,
                        selection: SessionSidebarSelection(selection: context.sidebarSelectionState.selection),
                        width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth))
                    )
                )
            }

        guard !windows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: windows
        )
    }

    #if DEBUG
        private func debugLogSessionSaveSnapshot(
            _ snapshot: AppSessionSnapshot,
            includeScrollback: Bool
        ) {
            dlog(
                "session.save includeScrollback=\(includeScrollback ? 1 : 0) " +
                    "windows=\(snapshot.windows.count)"
            )
            for (index, windowSnapshot) in snapshot.windows.enumerated() {
                let workspaceCount = windowSnapshot.tabManager.workspaces.count
                let selectedWorkspace = windowSnapshot.tabManager.selectedWorkspaceIndex.map(String.init) ?? "nil"
                dlog(
                    "session.save.window idx=\(index) " +
                        "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                        "display={\(debugSessionDisplayDescription(windowSnapshot.display))} " +
                        "workspaces=\(workspaceCount) selected=\(selectedWorkspace)"
                )
            }
        }

        private func debugSessionRectDescription(_ rect: SessionRectSnapshot?) -> String {
            guard let rect else { return "nil" }
            return "x=\(debugSessionNumber(rect.x)) y=\(debugSessionNumber(rect.y)) " +
                "w=\(debugSessionNumber(rect.width)) h=\(debugSessionNumber(rect.height))"
        }

        private func debugNSRectDescription(_ rect: NSRect?) -> String {
            guard let rect else { return "nil" }
            return "x=\(debugSessionNumber(Double(rect.origin.x))) " +
                "y=\(debugSessionNumber(Double(rect.origin.y))) " +
                "w=\(debugSessionNumber(Double(rect.size.width))) " +
                "h=\(debugSessionNumber(Double(rect.size.height)))"
        }

        private func debugSessionDisplayDescription(_ display: SessionDisplaySnapshot?) -> String {
            guard let display else { return "nil" }
            let displayIdText = display.displayID.map(String.init) ?? "nil"
            return "id=\(displayIdText) " +
                "frame={\(debugSessionRectDescription(display.frame))} " +
                "visible={\(debugSessionRectDescription(display.visibleFrame))}"
        }

        private func debugSessionNumber(_ value: Double) -> String {
            String(format: "%.1f", value)
        }
    #endif

    private func markCommandPaletteOpenRequested(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePendingOpenByWindowId[windowId] = true
        commandPaletteRecentRequestAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime
    }

    private func postCommandPaletteRequest(
        name: Notification.Name,
        preferredWindow: NSWindow?,
        source: String,
        markPending: Bool
    ) {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        if markPending {
            markCommandPaletteOpenRequested(for: targetWindow)
        }
        NotificationCenter.default.post(name: name, object: targetWindow)
        #if DEBUG
            dlog(
                "shortcut.palette.request source=\(source) " +
                    "target={\(debugWindowToken(targetWindow))} " +
                    "pendingMarked=\(markPending ? 1 : 0)"
            )
        #endif
    }

    private func clearCommandPalettePendingOpen(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
    }

    private func pruneExpiredCommandPalettePendingOpenStates(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        for windowId in Array(commandPalettePendingOpenByWindowId.keys) {
            guard commandPalettePendingOpenByWindowId[windowId] == true else { continue }
            guard let requestedAt = commandPaletteRecentRequestAtByWindowId[windowId] else {
                commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
                #if DEBUG
                    dlog("shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) reason=missingTimestamp")
                #endif
                continue
            }
            let age = now - requestedAt
            guard age > Self.commandPalettePendingOpenMaxAge else { continue }
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
            #if DEBUG
                dlog(
                    "shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) " +
                        "reason=stale ageMs=\(Int(age * 1000))"
                )
            #endif
        }
    }

    private func isCommandPalettePendingOpen(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        pruneExpiredCommandPalettePendingOpenStates()
        return commandPalettePendingOpenByWindowId[windowId] == true
    }

    private func beginCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteEscapeSuppressionByWindowId.insert(windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId[windowId] = ProcessInfo.processInfo.systemUptime
    }

    private func endCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteEscapeSuppressionByWindowId.remove(windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: windowId)
    }

    private func shouldConsumeSuppressedEscape(event: NSEvent, window: NSWindow?) -> Bool {
        guard let window,
              let windowId = mainWindowId(for: window),
              commandPaletteEscapeSuppressionByWindowId.contains(windowId)
        else {
            return false
        }
        if event.isARepeat {
            return true
        }
        let startedAt = commandPaletteEscapeSuppressionStartedAtByWindowId[windowId] ?? 0
        if ProcessInfo.processInfo.systemUptime - startedAt <= 0.35 {
            return true
        }
        // Fallback cleanup when keyUp is lost for any reason.
        endCommandPaletteEscapeSuppression(for: window)
        return false
    }

    private func recentCommandPaletteRequestAge(for window: NSWindow?) -> TimeInterval? {
        guard let window,
              let windowId = mainWindowId(for: window)
        else {
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredCommandPalettePendingOpenStates(now: now)
        guard commandPalettePendingOpenByWindowId[windowId] == true else {
            commandPaletteRecentRequestAtByWindowId.removeValue(forKey: windowId)
            return nil
        }
        guard let startedAt = commandPaletteRecentRequestAtByWindowId[windowId] else {
            commandPalettePendingOpenByWindowId.removeValue(forKey: windowId)
            return nil
        }
        let age = now - startedAt
        if age <= Self.commandPaletteRequestGraceInterval {
            return age
        }
        return nil
    }

    private func escapeSuppressionWindow(for event: NSEvent) -> NSWindow? {
        commandPaletteWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    @discardableResult
    private func clearEscapeSuppressionForKeyUp(event: NSEvent, consumeIfSuppressed: Bool = false) -> Bool {
        guard event.type == .keyUp, event.keyCode == 53 else { return false }
        let suppressionWindow = escapeSuppressionWindow(for: event)
        let didConsume = consumeIfSuppressed && shouldConsumeSuppressedEscape(event: event, window: suppressionWindow)
        if let window = suppressionWindow {
            endCommandPaletteEscapeSuppression(for: window)
            #if DEBUG
                dlog(
                    "shortcut.escape suppressionClear target={\(debugWindowToken(window))} " +
                        "keyUpConsumed=\(didConsume ? 1 : 0)"
                )
            #endif
            return didConsume
        }
        commandPaletteEscapeSuppressionByWindowId.removeAll()
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeAll()
        #if DEBUG
            dlog("shortcut.escape suppressionClear target={nil} clearedAll=1 keyUpConsumed=\(didConsume ? 1 : 0)")
        #endif
        return didConsume
    }

    private func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        if responder is GhosttyNSView || responder is WKWebView {
            return true
        }

        if let textView = responder as? NSTextView,
           !textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView
        {
            return isTerminalOrBrowserView(delegateView)
        }

        if let view = responder as? NSView {
            return isTerminalOrBrowserView(view)
        }

        return false
    }

    private func isTerminalOrBrowserView(_ view: NSView) -> Bool {
        if view is GhosttyNSView || view is WKWebView {
            return true
        }
        var current: NSView? = view.superview
        while let candidate = current {
            if candidate is GhosttyNSView || candidate is WKWebView {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    private func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    private func forEachTerminalPanel(_ body: (TerminalPanel) -> Void) {
        var seenManagers: Set<ObjectIdentifier> = []

        func visitManager(_ manager: TabManager?) {
            guard let manager else { return }
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let terminalPanel = panel as? TerminalPanel else { continue }
                    body(terminalPanel)
                }
            }
        }

        visitManager(tabManager)
        for context in mainWindowContexts.values {
            visitManager(context.tabManager)
        }
    }

    private func confirmCloseMainWindow(_ window: NSWindow) -> Bool {
        #if DEBUG
            if let debugCloseMainWindowConfirmationHandler {
                return debugCloseMainWindowConfirmationHandler(window)
            }
        #endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        alert.informativeText = String(
            localized: "dialog.closeWindow.message",
            defaultValue: "This will close the current window and all of its workspaces."
        )
        alert.addButton(withTitle: String(localized: "common.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        if let closeButton = alert.buttons.first {
            alertWindow.defaultButtonCell = closeButton.cell as? NSButtonCell
            alertWindow.initialFirstResponder = closeButton
            DispatchQueue.main.async {
                _ = alertWindow.makeFirstResponder(closeButton)
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        let summaries = listMainWindowSummaries()
        return summaries.sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = String(localized: "menu.currentWindow", defaultValue: "Current Window")
            } else {
                let number = index + 1
                labels[summary.windowId] = String(localized: "menu.windowNumber", defaultValue: "Window \(number)")
            }
        }
        return labels
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : trimmed
    }

    private func rollbackDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        to workspace: Workspace,
        sourcePane: PaneID?,
        sourceIndex: Int?,
        focus: Bool
    ) {
        let rollbackPane = sourcePane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let rollbackPane else { return }
        _ = workspace.attachDetachedSurface(
            detached,
            inPane: rollbackPane,
            atIndex: sourceIndex,
            focus: focus
        )
    }

    private func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        guard sourceWorkspace.panels.isEmpty else { return }
        guard sourceManager.tabs.contains(where: { $0.id == sourceWorkspace.id }) else { return }

        if sourceManager.tabs.count > 1 {
            sourceManager.closeWorkspace(sourceWorkspace)
        } else {
            _ = closeMainWindow(windowId: sourceWindowId)
        }
    }

    private func reassertCrossWindowSurfaceMoveFocusIfNeeded(
        destinationWindowId: UUID,
        sourceWindowId: UUID,
        destinationWorkspaceId: UUID,
        destinationPanelId: UUID,
        destinationManager: TabManager
    ) {
        let reassert: () -> Void = { [weak self, weak destinationManager] in
            guard let self, let destinationManager else { return }
            guard let workspace = destinationManager.tabs.first(where: { $0.id == destinationWorkspaceId }),
                  workspace.panels[destinationPanelId] != nil
            else {
                return
            }
            guard let destinationWindow = mainWindow(for: destinationWindowId) else { return }
            guard let keyWindow = NSApp.keyWindow,
                  let keyWindowId = mainWindowId(for: keyWindow),
                  keyWindowId == sourceWindowId,
                  keyWindow !== destinationWindow
            else {
                return
            }

            bringToFront(destinationWindow)
            destinationManager.focusTab(
                destinationWorkspaceId,
                surfaceId: destinationPanelId,
                suppressFlash: true
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reassert)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: reassert)
    }

    private func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window
        {
            return window
        }
        let expectedIdentifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    private func resolvedWindow(for context: MainWindowContext) -> NSWindow? {
        guard let window = context.window ?? windowForMainWindowId(context.windowId) else {
            return nil
        }
        context.window = window
        return window
    }

    private func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "cmux.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            return
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        if let conflicting = mainWindowContexts[desiredKey], conflicting !== context {
            context.window = window
            return
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
    }

    private func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId })
        {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           })
        {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    private func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = contextForMainTerminalWindow(window, reindex: false) else { return nil }
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        return removed
    }

    private func discardOrphanedMainWindowContext(_ context: MainWindowContext) {
        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        commandPaletteVisibilityByWindowId.removeValue(forKey: context.windowId)
        commandPalettePendingOpenByWindowId.removeValue(forKey: context.windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: context.windowId)
        commandPaletteEscapeSuppressionByWindowId.remove(context.windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: context.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: context.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: context.windowId)

        if tabManager === context.tabManager {
            if let nextContext = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil }) {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        if let store = notificationStore {
            for tab in context.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }
    }

    private func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("cmux.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("cmux.main.".count))
        return UUID(uuidString: idPart)
    }

    private func commandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    private func isCommandPaletteOverlayPresented(in window: NSWindow) -> Bool {
        guard let container = commandPaletteOverlayContainer(in: window) else { return false }
        return !container.isHidden && container.alphaValue > 0.001
    }

    private func isCommandPaletteResponderActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           !(textView.delegate is NSView)
        {
            // Field-editor delegates can be non-view responders. Confirm the overlay is
            // mounted and visible to avoid treating unrelated editors as palette input.
            return isCommandPaletteOverlayPresented(in: window)
        }
        return isCommandPaletteResponder(responder)
    }

    private func commandPaletteMarkedTextInput(in window: NSWindow) -> NSTextView? {
        if let textView = window.firstResponder as? NSTextView,
           isCommandPaletteResponder(textView),
           textView.hasMarkedText()
        {
            return textView
        }

        if let textField = window.firstResponder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView,
           isCommandPaletteResponder(editor),
           editor.hasMarkedText()
        {
            return editor
        }

        return nil
    }

    private func isCommandPaletteEffectivelyVisible(in window: NSWindow) -> Bool {
        isCommandPaletteVisible(for: window)
            || isCommandPalettePendingOpen(for: window)
            || isCommandPaletteOverlayPresented(in: window)
            || isCommandPaletteResponderActive(in: window)
    }

    private func activeCommandPaletteWindow() -> NSWindow? {
        pruneExpiredCommandPalettePendingOpenStates()
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow),
           isCommandPaletteEffectivelyVisible(in: keyWindow)
        {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow),
           isCommandPaletteEffectivelyVisible(in: mainWindow)
        {
            return mainWindow
        }
        if let orderedWindow = NSApp.orderedWindows.first(where: { window in
            isMainTerminalWindow(window) && isCommandPaletteEffectivelyVisible(in: window)
        }) {
            return orderedWindow
        }
        if let visibleWindowId = commandPaletteVisibilityByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(visibleWindowId)
        }
        if let pendingWindowId = commandPalettePendingOpenByWindowId.first(where: { $0.value })?.key {
            return windowForMainWindowId(pendingWindowId)
        }
        return nil
    }

    private func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

    private func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window, isMainTerminalWindow(window) else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)]
    }

    #if DEBUG
        private func debugManagerToken(_ manager: TabManager?) -> String {
            guard let manager else { return "nil" }
            return String(describing: Unmanaged.passUnretained(manager).toOpaque())
        }

        private func debugWindowToken(_ window: NSWindow?) -> String {
            guard let window else { return "nil" }
            let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
            let ident = window.identifier?.rawValue ?? "nil"
            let shortIdent: String = if ident.count > 120 {
                String(ident.prefix(120)) + "..."
            } else {
                ident
            }
            return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
        }

        private func debugContextToken(_ context: MainWindowContext?) -> String {
            guard let context else { return "nil" }
            let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
            return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
        }

        private func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
            let activeManager = tabManager
            let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
            let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

            let contexts = mainWindowContexts.values
                .map { context in
                    let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                    let window = context.window ?? windowForMainWindowId(context.windowId)
                    let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                    return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
                }
                .sorted()
                .joined(separator: ",")

            let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
            let eventWindow = event?.window
            return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(NSApp.keyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
        }
    #endif

    private func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let window = event.window, isMainTerminalWindow(window) {
            return window
        }
        let eventWindowNumber = event.windowNumber
        if eventWindowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: eventWindowNumber),
           isMainTerminalWindow(numberedWindow)
        {
            return numberedWindow
        }
        if let keyWindow = NSApp.keyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    private func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(NSApp.keyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager })
        {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    private func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
        #if DEBUG
            dlog(
                "shortcut.activate.pre event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
            )
        #endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
        #if DEBUG
            dlog(
                "shortcut.activate.post event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
            )
        #endif
    }

    private func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        didHandleExplicitOpenIntentAtStartup = true
        if !didAttemptStartupSessionRestore {
            startupSessionSnapshot = nil
            didAttemptStartupSessionRestore = true
        }

        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        for directory in directories {
            switch target {
                case .window:
                    _ = createMainWindow(initialWorkingDirectory: directory)
                case .workspace:
                    openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !pathURLs.isEmpty {
            return pathURLs
        }

        let filenamesType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                return urls
            }
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    private func openWorkspaceFromService(workingDirectory: String) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: "service.openTab"
        ) != nil {
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    private func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: debugSource) {
            return context
        }

        // If a keyboard event identifies a specific window but that context
        // can't be resolved, do not fall back to another window.
        if shortcutEventHasAddressableWindow(event) {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "event_context_required_no_fallback",
                    event: event,
                    chosenContext: nil
                )
            #endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow)
        {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "key_window",
                    event: event,
                    chosenContext: context
                )
            #endif
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow)
        {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "main_window",
                    event: event,
                    chosenContext: context
                )
            #endif
            return context
        }

        for window in NSApp.orderedWindows where isMainTerminalWindow(window) {
            if let context = contextForMainTerminalWindow(window) {
                #if DEBUG
                    logWorkspaceCreationRouting(
                        phase: "choose",
                        source: debugSource,
                        reason: "ordered_windows",
                        event: event,
                        chosenContext: context
                    )
                #endif
                return context
            }
        }

        let fallback = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil })
        #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "fallback_first_context",
                event: event,
                chosenContext: fallback
            )
        #endif
        return fallback
    }

    private func shortcutEventHasAddressableWindow(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        // NSEvent.windowNumber can be 0 for responder-chain events that are not
        // actually bound to an NSWindow (notably some WebKit key paths).
        return event.window != nil || event.windowNumber > 0
    }

    private func mainWindowContext(
        forShortcutEvent event: NSEvent?,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
        guard let event else { return nil }

        if let eventWindow = event.window,
           let context = contextForMainTerminalWindow(eventWindow)
        {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "event_window",
                    event: event,
                    chosenContext: context
                )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           let context = contextForMainTerminalWindow(numberedWindow)
        {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "event_window_number",
                    event: event,
                    chosenContext: context
                )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let window = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return window?.windowNumber == event.windowNumber
           })
        {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "event_window_number_scan",
                    event: event,
                    chosenContext: context
                )
            #endif
            return context
        }

        #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_context_not_found",
                event: event,
                chosenContext: nil
            )
        #endif
        return nil
    }

    private func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: "shortcut.routing",
                    reason: "event_context_required_no_fallback",
                    event: event,
                    chosenContext: nil
                )
            #endif
            return nil
        }

        if let keyWindow = NSApp.keyWindow,
           let context = contextForMainTerminalWindow(keyWindow)
        {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow)
        {
            return context
        }

        if let activeManager = tabManager,
           let context = mainWindowContexts.values.first(where: { $0.tabManager === activeManager })
        {
            return context
        }

        return mainWindowContexts.values.first
    }

    @discardableResult
    private func synchronizeShortcutRoutingContext(event: NSEvent) -> Bool {
        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
            #if DEBUG
                FocusLogStore.shared.append(
                    "shortcut.route reason=no_context_no_fallback eventWin=\(event.windowNumber) keyCode=\(event.keyCode)"
                )
            #endif
            return false
        }

        let alreadyActive =
            tabManager === context.tabManager
                && sidebarState === context.sidebarState
                && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive { return true }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }

        #if DEBUG
            FocusLogStore.shared.append(
                "shortcut.route reason=sync activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(context))}"
            )
        #endif
        return true
    }

    private func presentCLIPathAlert(
        title: String,
        informativeText: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    private func setupMenuBarExtra() {
        guard menuBarExtraController == nil else { return }
        let store = TerminalNotificationStore.shared
        menuBarExtraController = MenuBarExtraController(
            notificationStore: store,
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openNotification(
                    tabId: notification.tabId,
                    surfaceId: notification.surfaceId,
                    notificationId: notification.id
                )
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    private func installMenuBarVisibilityObserver() {
        guard menuBarVisibilityObserver == nil else { return }
        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMenuBarExtraVisibility()
            }
        }
    }

    private func syncMenuBarExtraVisibility(defaults: UserDefaults = .standard) {
        if MenuBarExtraSettings.showsMenuBarExtra(defaults: defaults) {
            setupMenuBarExtra()
            return
        }

        menuBarExtraController?.removeFromMenuBar()
        menuBarExtraController = nil
    }

    private func sendTextWhenReady(_ text: String, to tab: Tab, attempt: Int = 0, beforeSend: (() -> Void)? = nil) {
        let maxAttempts = 60
        if let terminalPanel = tab.focusedTerminalPanel, terminalPanel.surface.surface != nil {
            beforeSend?()
            terminalPanel.sendText(text)
            return
        }
        guard attempt < maxAttempts else {
            NSLog("Command send: surface not ready after \(maxAttempts) attempts")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.sendTextWhenReady(text, to: tab, attempt: attempt + 1, beforeSend: beforeSend)
        }
    }

    #if DEBUG
        private func setupJumpUnreadUITestIfNeeded() {
            guard !didSetupJumpUnreadUITest else { return }
            didSetupJumpUnreadUITest = true
            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
            guard let notificationStore else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                    // registered main terminal window context so notifications can be routed back correctly.
                    let deadline = Date().addingTimeInterval(8.0)
                    @MainActor func waitForContext(_ completion: @escaping (MainWindowContext) -> Void) {
                        if let context = self.mainWindowContexts.values.first,
                           context.window != nil
                        {
                            completion(context)
                            return
                        }
                        guard Date() < deadline else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            Task { @MainActor in
                                waitForContext(completion)
                            }
                        }
                    }

                    waitForContext { context in
                        let tabManager = context.tabManager
                        let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                        let tab = tabManager.addTab()
                        guard let initialPanelId = tab.focusedPanelId else { return }

                        _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                        guard let targetPanelId = tab.focusedPanelId else { return }
                        // Find another panel that's not the currently focused one
                        let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                        if let otherPanelId {
                            tab.focusPanel(otherPanelId)
                        }

                        // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                        // cause notification suppression to incorrectly drop this UI-test notification.
                        let prevOverride = AppFocusState.overrideIsFocused
                        AppFocusState.overrideIsFocused = false
                        notificationStore.addNotification(
                            tabId: tab.id,
                            surfaceId: targetPanelId,
                            title: "JumpToUnread",
                            subtitle: "",
                            body: ""
                        )
                        AppFocusState.overrideIsFocused = prevOverride

                        self.writeJumpUnreadTestData([
                            "expectedTabId": tab.id.uuidString,
                            "expectedSurfaceId": targetPanelId.uuidString,
                        ])

                        tabManager.selectTab(at: initialIndex)
                    }
                }
            }
        }

        func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
            writeJumpUnreadTestData([
                "focusedTabId": tabId.uuidString,
                "focusedSurfaceId": surfaceId.uuidString,
            ])
        }

        func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
            jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
            installJumpUnreadFocusObserverIfNeeded()
        }

        func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
            guard let expectation = jumpUnreadFocusExpectation else { return }
            guard expectation.tabId == tabId, expectation.surfaceId == surfaceId else { return }
            jumpUnreadFocusExpectation = nil
            recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
            if let jumpUnreadFocusObserver {
                NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
                self.jumpUnreadFocusObserver = nil
            }
        }

        private func installJumpUnreadFocusObserverIfNeeded() {
            guard jumpUnreadFocusObserver == nil else { return }
            jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
            }
        }

        private func writeJumpUnreadTestData(_ updates: [String: String]) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
            var payload = loadJumpUnreadTestData(at: path)
            for (key, value) in updates {
                payload[key] = value
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func loadJumpUnreadTestData(at path: String) -> [String: String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                return [:]
            }
            return object
        }

        private func setupGotoSplitUITestIfNeeded() {
            guard !didSetupGotoSplitUITest else { return }
            didSetupGotoSplitUITest = true
            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
            guard tabManager != nil else { return }

            let useGhosttyConfig = env["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] == "1"

            if useGhosttyConfig {
                // Keep the test hermetic: ensure the app does not accidentally pass using a persisted
                // KeyboardShortcutSettings override instead of the Ghostty config-trigger path.
                UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusLeftKey)
                UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusRightKey)
                UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusUpKey)
                UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusDownKey)
            } else {
                // For this UI test we want a letter-based shortcut (Cmd+Ctrl+H) to drive pane navigation,
                // since arrow keys can't be recorded by the shortcut recorder.
                KeyboardShortcutSettings.setShortcut(
                    StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
                    for: .focusLeft
                )
                KeyboardShortcutSettings.setShortcut(
                    StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
                    for: .focusRight
                )
                KeyboardShortcutSettings.setShortcut(
                    StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
                    for: .focusUp
                )
                KeyboardShortcutSettings.setShortcut(
                    StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
                    for: .focusDown
                )
            }

            installGotoSplitUITestFocusObserversIfNeeded()

            // On the VM, launching/initializing multiple windows can occasionally take longer than a
            // few seconds; keep the deadline generous so the test doesn't flake.
            let deadline = Date().addingTimeInterval(20.0)
            func hasMainTerminalWindow() -> Bool {
                NSApp.windows.contains { window in
                    guard let raw = window.identifier?.rawValue else { return false }
                    return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
                }
            }

            func runSetupWhenWindowReady() {
                guard Date() < deadline else {
                    writeGotoSplitTestData(["setupError": "Timed out waiting for main window"])
                    return
                }
                guard hasMainTerminalWindow() else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        runSetupWhenWindowReady()
                    }
                    return
                }
                guard let tabManager else { return }

                let tab = tabManager.addTab()
                guard let initialPanelId = tab.focusedPanelId else {
                    writeGotoSplitTestData(["setupError": "Missing initial panel id"])
                    return
                }

                let url = URL(string: "https://example.com")
                guard let browserPanelId = tabManager.newBrowserSplit(
                    tabId: tab.id,
                    fromPanelId: initialPanelId,
                    orientation: .horizontal,
                    url: url
                ) else {
                    writeGotoSplitTestData(["setupError": "Failed to create browser split"])
                    return
                }

                focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard self != nil else { return }
                runSetupWhenWindowReady()
            }
        }

        private func isGotoSplitUITestRecordingEnabled() -> Bool {
            let env = ProcessInfo.processInfo.environment
            return env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" || env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
        }

        private func gotoSplitUITestDataPath() -> String? {
            guard isGotoSplitUITestRecordingEnabled() else { return nil }
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
            return path
        }

        private func gotoSplitFindStateSnapshot(for workspace: Workspace) -> [String: String] {
            var updates: [String: String] = [
                "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? "",
            ]

            if let focusedPanelId = workspace.focusedPanelId {
                updates["focusedPanelId"] = focusedPanelId.uuidString
                if let terminal = workspace.terminalPanel(for: focusedPanelId) {
                    updates["focusedPanelKind"] = "terminal"
                    updates["focusedTerminalFindNeedle"] = terminal.searchState?.needle ?? ""
                    updates["focusedBrowserFindNeedle"] = ""
                } else if let browser = workspace.browserPanel(for: focusedPanelId) {
                    updates["focusedPanelKind"] = "browser"
                    updates["focusedBrowserFindNeedle"] = browser.searchState?.needle ?? ""
                    updates["focusedTerminalFindNeedle"] = ""
                } else {
                    updates["focusedPanelKind"] = "other"
                    updates["focusedTerminalFindNeedle"] = ""
                    updates["focusedBrowserFindNeedle"] = ""
                }
            } else {
                updates["focusedPanelId"] = ""
                updates["focusedPanelKind"] = "none"
                updates["focusedTerminalFindNeedle"] = ""
                updates["focusedBrowserFindNeedle"] = ""
            }

            let terminalWithFind = workspace.panels
                .values
                .compactMap { $0 as? TerminalPanel }
                .first(where: { $0.searchState != nil })
            updates["terminalFindPanelId"] = terminalWithFind?.id.uuidString ?? ""
            updates["terminalFindNeedle"] = terminalWithFind?.searchState?.needle ?? ""

            let browserWithFind = workspace.panels
                .values
                .compactMap { $0 as? BrowserPanel }
                .first(where: { $0.searchState != nil })
            updates["browserFindPanelId"] = browserWithFind?.id.uuidString ?? ""
            updates["browserFindNeedle"] = browserWithFind?.searchState?.needle ?? ""

            return updates
        }

        private func focusWebViewForGotoSplitUITest(tab: Workspace, browserPanelId: UUID, attempt: Int = 0) {
            let maxAttempts = 120
            guard attempt < maxAttempts else {
                writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Timed out waiting for WKWebView focus",
                ])
                return
            }

            guard let browserPanel = tab.browserPanel(for: browserPanelId) else {
                writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Browser panel missing",
                ])
                return
            }

            // Select the browser surface and try to focus the WKWebView.
            tab.focusPanel(browserPanelId)

            if isWebViewFocused(browserPanel),
               let (browserPaneId, terminalPaneId) = paneIdsForGotoSplitUITest(
                   tab: tab,
                   browserPanelId: browserPanelId
               )
            {
                writeGotoSplitTestData([
                    "browserPanelId": browserPanelId.uuidString,
                    "browserPaneId": browserPaneId.description,
                    "terminalPaneId": terminalPaneId.description,
                    "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                    "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                    "ghosttyGotoSplitLeftShortcut": ghosttyGotoSplitLeftShortcut?.displayString ?? "",
                    "ghosttyGotoSplitRightShortcut": ghosttyGotoSplitRightShortcut?.displayString ?? "",
                    "ghosttyGotoSplitUpShortcut": ghosttyGotoSplitUpShortcut?.displayString ?? "",
                    "ghosttyGotoSplitDownShortcut": ghosttyGotoSplitDownShortcut?.displayString ?? "",
                    "webViewFocused": "true",
                ])
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] == "1" {
                    setupFocusedInputForGotoSplitUITest(panel: browserPanel)
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId, attempt: attempt + 1)
            }
        }

        private func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
            guard let window = panel.webView.window else { return false }
            guard let fr = window.firstResponder as? NSView else { return false }
            return fr.isDescendant(of: panel.webView)
        }

        private func paneIdsForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
            let paneIds = tab.bonsplitController.allPaneIds
            guard paneIds.count >= 2 else { return nil }

            var browserPane: PaneID?
            var terminalPane: PaneID?
            for paneId in paneIds {
                guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                      let panelId = tab.panelIdFromSurfaceId(selected.id) else { continue }
                if panelId == browserPanelId {
                    browserPane = paneId
                } else if terminalPane == nil {
                    terminalPane = paneId
                }
            }

            guard let browserPane, let terminalPane else { return nil }
            return (browserPane, terminalPane)
        }

        private func installGotoSplitUITestFocusObserversIfNeeded() {
            guard gotoSplitUITestObservers.isEmpty else { return }

            gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
                forName: .browserFocusAddressBar,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
                recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarFocus")
            })

            gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
                forName: .browserDidExitAddressBar,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                guard let panelId = notification.object as? UUID else { return }
                recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
                recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarExit")
            })
        }

        private func recordGotoSplitUITestWebViewFocus(panelId: UUID, key: String) {
            // Give the responder chain time to settle, retrying for slow environments (e.g. VM).
            recordGotoSplitUITestWebViewFocusRetry(panelId: panelId, key: key, attempt: 0)
        }

        private func recordGotoSplitUITestWebViewFocusRetry(panelId: UUID, key: String, attempt: Int) {
            let delays: [Double] = [0.05, 0.1, 0.25, 0.5]
            let delay = attempt < delays.count ? delays[attempt] : delays.last!
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let tabManager, let tab = tabManager.selectedWorkspace,
                      let panel = tab.browserPanel(for: panelId) else { return }
                let focused = isWebViewFocused(panel)
                // If focus hasn't settled yet and we have retries left, try again.
                if !focused, key.contains("Exit"), attempt < delays.count - 1 {
                    recordGotoSplitUITestWebViewFocusRetry(panelId: panelId, key: key, attempt: attempt + 1)
                    return
                }
                writeGotoSplitTestData([
                    key: focused ? "true" : "false",
                    "\(key)PanelId": panelId.uuidString,
                ])
            }
        }

        private func setupFocusedInputForGotoSplitUITest(panel: BrowserPanel, attempt: Int = 0) {
            let maxAttempts = 80
            guard attempt < maxAttempts else {
                writeGotoSplitTestData([
                    "webInputFocusSeeded": "false",
                    "setupError": "Timed out focusing page input for omnibar restore test",
                ])
                return
            }

            let script = """
            (() => {
              try {
                const trackerInstalled = window.__cmuxAddressBarFocusTrackerInstalled === true;
                const readyState = String(document.readyState || "");
                if (!trackerInstalled || readyState !== "complete") {
                  const active = document.activeElement;
                  return {
                    focused: false,
                    id: "",
                    activeId: active && typeof active.id === "string" ? active.id : "",
                    activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
                    trackerInstalled,
                    trackedStateId:
                      window.__cmuxAddressBarFocusState &&
                      typeof window.__cmuxAddressBarFocusState.id === "string"
                        ? window.__cmuxAddressBarFocusState.id
                        : "",
                    readyState
                  };
                }

                const ensureInput = (id, value) => {
                  const existing = document.getElementById(id);
                  const input = (existing && existing.tagName && existing.tagName.toLowerCase() === "input")
                    ? existing
                    : (() => {
                        const created = document.createElement("input");
                        created.id = id;
                        created.type = "text";
                        created.value = value;
                        return created;
                      })();
                  input.autocapitalize = "off";
                  input.autocomplete = "off";
                  input.spellcheck = false;
                  input.style.display = "block";
                  input.style.width = "100%";
                  input.style.margin = "0";
                  input.style.padding = "8px 10px";
                  input.style.border = "1px solid #5f6368";
                  input.style.borderRadius = "6px";
                  input.style.boxSizing = "border-box";
                  input.style.fontSize = "14px";
                  input.style.fontFamily = "system-ui, -apple-system, sans-serif";
                  input.style.background = "white";
                  input.style.color = "black";
                  return input;
                };

                let container = document.getElementById("cmux-ui-test-focus-container");
                if (!container || !container.tagName || container.tagName.toLowerCase() !== "div") {
                  container = document.createElement("div");
                  container.id = "cmux-ui-test-focus-container";
                  document.body.appendChild(container);
                }
                container.style.position = "fixed";
                container.style.left = "24px";
                container.style.top = "24px";
                container.style.width = "min(520px, calc(100vw - 48px))";
                container.style.display = "grid";
                container.style.rowGap = "12px";
                container.style.padding = "12px";
                container.style.background = "rgba(255,255,255,0.92)";
                container.style.border = "1px solid rgba(95,99,104,0.55)";
                container.style.borderRadius = "8px";
                container.style.boxShadow = "0 2px 10px rgba(0,0,0,0.2)";
                container.style.zIndex = "2147483647";

                const input = ensureInput("cmux-ui-test-focus-input", "cmux-ui-focus-primary");
                const secondaryInput = ensureInput("cmux-ui-test-focus-input-secondary", "cmux-ui-focus-secondary");
                if (input.parentElement !== container) {
                  container.appendChild(input);
                }
                if (secondaryInput.parentElement !== container) {
                  container.appendChild(secondaryInput);
                }

                input.focus({ preventScroll: true });
                if (typeof input.setSelectionRange === "function") {
                  const end = input.value.length;
                  input.setSelectionRange(end, end);
                }

                let trackedFocusId = input.getAttribute("data-cmux-addressbar-focus-id");
                if (!trackedFocusId) {
                  trackedFocusId = "cmux-ui-test-focus-input-tracked";
                  input.setAttribute("data-cmux-addressbar-focus-id", trackedFocusId);
                }
                const selectionStart = typeof input.selectionStart === "number" ? input.selectionStart : null;
                const selectionEnd = typeof input.selectionEnd === "number" ? input.selectionEnd : null;
                if (
                  !window.__cmuxAddressBarFocusState ||
                  typeof window.__cmuxAddressBarFocusState.id !== "string" ||
                  window.__cmuxAddressBarFocusState.id !== trackedFocusId
                ) {
                  window.__cmuxAddressBarFocusState = { id: trackedFocusId, selectionStart, selectionEnd };
                }

                const secondaryRect = secondaryInput.getBoundingClientRect();
                const viewportWidth = Math.max(Number(window.innerWidth) || 0, 1);
                const viewportHeight = Math.max(Number(window.innerHeight) || 0, 1);
                const secondaryCenterX = Math.min(
                  0.98,
                  Math.max(0.02, (secondaryRect.left + (secondaryRect.width / 2)) / viewportWidth)
                );
                const secondaryCenterY = Math.min(
                  0.98,
                  Math.max(0.02, (secondaryRect.top + (secondaryRect.height / 2)) / viewportHeight)
                );
                const active = document.activeElement;
                return {
                  focused: active === input,
                  id: input.id || "",
                  secondaryId: secondaryInput.id || "",
                  secondaryCenterX,
                  secondaryCenterY,
                  activeId: active && typeof active.id === "string" ? active.id : "",
                  activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
                  trackerInstalled,
                  trackedStateId:
                    window.__cmuxAddressBarFocusState &&
                    typeof window.__cmuxAddressBarFocusState.id === "string"
                      ? window.__cmuxAddressBarFocusState.id
                      : "",
                  readyState
                };
              } catch (_) {
                return {
                  focused: false,
                  id: "",
                  secondaryId: "",
                  secondaryCenterX: -1,
                  secondaryCenterY: -1,
                  activeId: "",
                  activeTag: "",
                  trackerInstalled: false,
                  trackedStateId: "",
                  readyState: ""
                };
              }
            })();
            """

            panel.webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                let payload = result as? [String: Any]
                let focused = (payload?["focused"] as? Bool) ?? false
                let inputId = (payload?["id"] as? String) ?? ""
                let secondaryInputId = (payload?["secondaryId"] as? String) ?? ""
                let secondaryCenterX = (payload?["secondaryCenterX"] as? NSNumber)?.doubleValue ?? -1
                let secondaryCenterY = (payload?["secondaryCenterY"] as? NSNumber)?.doubleValue ?? -1
                let activeId = (payload?["activeId"] as? String) ?? ""
                let trackerInstalled = (payload?["trackerInstalled"] as? Bool) ?? false
                let trackedStateId = (payload?["trackedStateId"] as? String) ?? ""
                let readyState = (payload?["readyState"] as? String) ?? ""
                var secondaryClickOffsetX = -1.0
                var secondaryClickOffsetY = -1.0
                if let window = panel.webView.window {
                    let webFrame = panel.webView.convert(panel.webView.bounds, to: nil)
                    let contentHeight = Double(window.contentView?.bounds.height ?? 0)
                    if webFrame.width > 1,
                       webFrame.height > 1,
                       contentHeight > 1,
                       secondaryCenterX > 0,
                       secondaryCenterX < 1,
                       secondaryCenterY > 0,
                       secondaryCenterY < 1
                    {
                        let xInContent = Double(webFrame.minX) + (secondaryCenterX * Double(webFrame.width))
                        let yFromTopInWeb = secondaryCenterY * Double(webFrame.height)
                        let yInContent = Double(webFrame.maxY) - yFromTopInWeb
                        let yFromTopInContent = contentHeight - yInContent
                        let titlebarHeight = max(0, Double(window.frame.height) - contentHeight)
                        secondaryClickOffsetX = xInContent
                        secondaryClickOffsetY = titlebarHeight + yFromTopInContent
                    }
                }
                if focused,
                   !inputId.isEmpty,
                   !secondaryInputId.isEmpty,
                   inputId == activeId,
                   trackerInstalled,
                   !trackedStateId.isEmpty,
                   secondaryCenterX > 0,
                   secondaryCenterX < 1,
                   secondaryCenterY > 0,
                   secondaryCenterY < 1,
                   secondaryClickOffsetX > 0,
                   secondaryClickOffsetY > 0
                {
                    writeGotoSplitTestData([
                        "webInputFocusSeeded": "true",
                        "webInputFocusElementId": inputId,
                        "webInputFocusSecondaryElementId": secondaryInputId,
                        "webInputFocusSecondaryCenterX": "\(secondaryCenterX)",
                        "webInputFocusSecondaryCenterY": "\(secondaryCenterY)",
                        "webInputFocusSecondaryClickOffsetX": "\(secondaryClickOffsetX)",
                        "webInputFocusSecondaryClickOffsetY": "\(secondaryClickOffsetY)",
                        "webInputFocusActiveElementId": activeId,
                        "webInputFocusTrackerInstalled": trackerInstalled ? "true" : "false",
                        "webInputFocusTrackedStateId": trackedStateId,
                        "webInputFocusReadyState": readyState,
                    ])
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.setupFocusedInputForGotoSplitUITest(panel: panel, attempt: attempt + 1)
                }
            }
        }

        private func recordGotoSplitUITestActiveElement(panelId: UUID, keyPrefix: String) {
            recordGotoSplitUITestActiveElementRetry(panelId: panelId, keyPrefix: keyPrefix, attempt: 0)
        }

        private func recordGotoSplitUITestActiveElementRetry(panelId: UUID, keyPrefix: String, attempt: Int) {
            let delays: [Double] = [0.05, 0.1, 0.25, 0.5]
            let delay = attempt < delays.count ? delays[attempt] : delays.last!
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      let tabManager,
                      let tab = tabManager.selectedWorkspace,
                      let panel = tab.browserPanel(for: panelId) else { return }

                evaluateGotoSplitUITestActiveElement(panel: panel) { snapshot in
                    let activeId = snapshot["id"] ?? ""
                    let expectedInputId = self.gotoSplitUITestExpectedInputId() ?? ""
                    if keyPrefix == "addressBarExit",
                       !expectedInputId.isEmpty,
                       activeId != expectedInputId,
                       attempt < delays.count - 1
                    {
                        self.recordGotoSplitUITestActiveElementRetry(
                            panelId: panelId,
                            keyPrefix: keyPrefix,
                            attempt: attempt + 1
                        )
                        return
                    }

                    self.writeGotoSplitTestData([
                        "\(keyPrefix)PanelId": panelId.uuidString,
                        "\(keyPrefix)ActiveElementId": activeId,
                        "\(keyPrefix)ActiveElementTag": snapshot["tag"] ?? "",
                        "\(keyPrefix)ActiveElementType": snapshot["type"] ?? "",
                        "\(keyPrefix)ActiveElementEditable": snapshot["editable"] ?? "false",
                        "\(keyPrefix)TrackedFocusStateId": snapshot["trackedFocusStateId"] ?? "",
                        "\(keyPrefix)FocusTrackerInstalled": snapshot["focusTrackerInstalled"] ?? "false",
                    ])
                }
            }
        }

        private func evaluateGotoSplitUITestActiveElement(
            panel: BrowserPanel,
            completion: @escaping ([String: String]) -> Void
        ) {
            let script = """
            (() => {
              try {
                const active = document.activeElement;
                if (!active) {
                  return { id: "", tag: "", type: "", editable: "false" };
                }
                const tag = (active.tagName || "").toLowerCase();
                const type = (active.type || "").toLowerCase();
                const editable =
                  !!active.isContentEditable ||
                  tag === "textarea" ||
                  (tag === "input" && type !== "hidden");
                return {
                  id: typeof active.id === "string" ? active.id : "",
                  tag,
                  type,
                  editable: editable ? "true" : "false",
                  trackedFocusStateId:
                    window.__cmuxAddressBarFocusState &&
                    typeof window.__cmuxAddressBarFocusState.id === "string"
                      ? window.__cmuxAddressBarFocusState.id
                      : "",
                  focusTrackerInstalled:
                    window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
                };
              } catch (_) {
                return {
                  id: "",
                  tag: "",
                  type: "",
                  editable: "false",
                  trackedFocusStateId: "",
                  focusTrackerInstalled: "false"
                };
              }
            })();
            """

            panel.webView.evaluateJavaScript(script) { result, _ in
                let payload = result as? [String: Any]
                completion([
                    "id": (payload?["id"] as? String) ?? "",
                    "tag": (payload?["tag"] as? String) ?? "",
                    "type": (payload?["type"] as? String) ?? "",
                    "editable": (payload?["editable"] as? String) ?? "false",
                    "trackedFocusStateId": (payload?["trackedFocusStateId"] as? String) ?? "",
                    "focusTrackerInstalled": (payload?["focusTrackerInstalled"] as? String) ?? "false",
                ])
            }
        }

        private func gotoSplitUITestExpectedInputId() -> String? {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
            return loadGotoSplitTestData(at: path)["webInputFocusElementId"]
        }

        private func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
            guard isGotoSplitUITestRecordingEnabled() else { return }
            guard let tabManager, let workspace = tabManager.selectedWorkspace else { return }

            let directionValue = switch direction {
                case .left:
                    "left"
                case .right:
                    "right"
                case .up:
                    "up"
                case .down:
                    "down"
            }

            var updates = gotoSplitFindStateSnapshot(for: workspace)
            updates["lastMoveDirection"] = directionValue
            writeGotoSplitTestData(updates)
        }

        private func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
            guard isGotoSplitUITestRecordingEnabled() else { return }
            guard let workspace = tabManager?.selectedWorkspace else { return }

            let directionValue = switch direction {
                case .left:
                    "left"
                case .right:
                    "right"
                case .up:
                    "up"
                case .down:
                    "down"
            }

            var updates = gotoSplitFindStateSnapshot(for: workspace)
            updates["lastSplitDirection"] = directionValue
            updates["paneCountAfterSplit"] = String(workspace.bonsplitController.allPaneIds.count)
            writeGotoSplitTestData(updates)
        }

        private func recordGotoSplitZoomIfNeeded() {
            guard isGotoSplitUITestRecordingEnabled() else { return }
            recordGotoSplitZoomRetry(attempt: 0)
        }

        private func recordGotoSplitZoomRetry(attempt: Int) {
            let delays: [Double] = [0.05, 0.1, 0.2, 0.35, 0.5]
            let delay = attempt < delays.count ? delays[attempt] : delays.last!

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      let workspace = tabManager?.selectedWorkspace else { return }

                let browserPanel = workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
                let otherTerminal = workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
                let browserSnapshot = browserPanel.flatMap {
                    BrowserWindowPortalRegistry.debugSnapshot(for: $0.webView)
                }

                var updates = gotoSplitFindStateSnapshot(for: workspace)
                updates["splitZoomedAfterToggle"] = workspace.bonsplitController.isSplitZoomed ? "true" : "false"
                updates["zoomedPaneIdAfterToggle"] = workspace.bonsplitController.zoomedPaneId?.description ?? ""
                updates["browserPanelIdAfterToggle"] = browserPanel?.id.uuidString ?? ""
                updates["browserContainerHiddenAfterToggle"] = browserSnapshot.map { $0.containerHidden ? "true" : "false" } ?? ""
                updates["browserVisibleFlagAfterToggle"] = browserSnapshot.map { $0.visibleInUI ? "true" : "false" } ?? ""
                updates["browserFrameAfterToggle"] = browserSnapshot.map {
                    String(
                        format: "%.1f,%.1f %.1fx%.1f",
                        $0.frameInWindow.origin.x,
                        $0.frameInWindow.origin.y,
                        $0.frameInWindow.size.width,
                        $0.frameInWindow.size.height
                    )
                } ?? ""
                updates["otherTerminalPanelIdAfterToggle"] = otherTerminal?.id.uuidString ?? ""
                updates["otherTerminalHostHiddenAfterToggle"] = otherTerminal.map { $0.hostedView.isHidden ? "true" : "false" } ?? ""
                updates["otherTerminalVisibleFlagAfterToggle"] = otherTerminal.map { $0.hostedView.debugPortalVisibleInUI ? "true" : "false" } ?? ""
                updates["otherTerminalFrameAfterToggle"] = otherTerminal.map {
                    let frame = $0.hostedView.debugPortalFrameInWindow
                    return String(
                        format: "%.1f,%.1f %.1fx%.1f",
                        frame.origin.x,
                        frame.origin.y,
                        frame.size.width,
                        frame.size.height
                    )
                } ?? ""

                let settled: Bool = {
                    if workspace.bonsplitController.isSplitZoomed {
                        if let focusedPanelId = workspace.focusedPanelId,
                           workspace.terminalPanel(for: focusedPanelId) != nil
                        {
                            guard let browserSnapshot else { return false }
                            return browserSnapshot.containerHidden && !browserSnapshot.visibleInUI
                        }
                        guard let otherTerminal else { return true }
                        return otherTerminal.hostedView.isHidden && !otherTerminal.hostedView.debugPortalVisibleInUI
                    }
                    let browserRestored = browserSnapshot.map { !$0.containerHidden && $0.visibleInUI } ?? true
                    let terminalRestored = otherTerminal.map {
                        !$0.hostedView.isHidden && $0.hostedView.debugPortalVisibleInUI
                    } ?? true
                    return browserRestored && terminalRestored
                }()

                if !settled, attempt < delays.count - 1 {
                    recordGotoSplitZoomRetry(attempt: attempt + 1)
                    return
                }

                writeGotoSplitTestData(updates)
            }
        }

        private func writeGotoSplitTestData(_ updates: [String: String]) {
            guard let path = gotoSplitUITestDataPath() else { return }
            var payload = loadGotoSplitTestData(at: path)
            for (key, value) in updates {
                payload[key] = value
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func loadGotoSplitTestData(at path: String) -> [String: String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                return [:]
            }
            return object
        }

        private func setupMultiWindowNotificationsUITestIfNeeded() {
            guard !didSetupMultiWindowNotificationsUITest else { return }
            didSetupMultiWindowNotificationsUITest = true

            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] == "1" else { return }
            guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

            try? FileManager.default.removeItem(atPath: path)

            let contextDeadline = Date().addingTimeInterval(8.0)
            func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
                if mainWindowContexts.count >= minCount,
                   mainWindowContexts.values.allSatisfy({ $0.window != nil })
                {
                    completion()
                    return
                }
                guard Date() < contextDeadline else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    waitForContexts(minCount: minCount, completion)
                }
            }

            func waitForSurfaceId(
                on tabManager: TabManager,
                tabId: UUID,
                timeout: TimeInterval = 8.0,
                _ completion: @escaping (UUID) -> Void
            ) {
                let deadline = Date().addingTimeInterval(timeout)

                func resolvedSurfaceId() -> UUID? {
                    if let surfaceId = tabManager.focusedPanelId(for: tabId) {
                        return surfaceId
                    }

                    guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                        return nil
                    }

                    if let terminalPanelId = workspace.focusedTerminalPanel?.id {
                        return terminalPanelId
                    }

                    if let terminalPanelId = workspace.terminalPanelForConfigInheritance()?.id {
                        return terminalPanelId
                    }

                    return workspace.panels
                        .values
                        .compactMap { ($0 as? TerminalPanel)?.id }
                        .sorted(by: { $0.uuidString < $1.uuidString })
                        .first
                }

                func poll() {
                    if let surfaceId = resolvedSurfaceId() {
                        completion(surfaceId)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        poll()
                    }
                }

                poll()
            }

            waitForContexts(minCount: 1) { [weak self] in
                guard let self else { return }
                guard let window1 = mainWindowContexts.values.first else { return }
                guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

                // Create a second main terminal window.
                openNewMainWindow(nil)

                waitForContexts(minCount: 2) { [weak self] in
                    guard let self else { return }
                    let contexts = Array(mainWindowContexts.values)
                    guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                    guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                    waitForSurfaceId(on: window1.tabManager, tabId: tabId1) { [weak self] surfaceId1 in
                        guard let self else { return }
                        waitForSurfaceId(on: window2.tabManager, tabId: tabId2) { [weak self] surfaceId2 in
                            guard let self else { return }
                            guard let store = notificationStore else { return }

                            // Ensure the target window is currently showing the Notifications overlay,
                            // so opening a notification must switch it back to the terminal UI.
                            window2.sidebarSelectionState.selection = .notifications

                            // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                            let prevOverride = AppFocusState.overrideIsFocused
                            AppFocusState.overrideIsFocused = false
                            store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                            AppFocusState.overrideIsFocused = prevOverride

                            // Insert after W2 so it becomes "latest unread" (first in list).
                            store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                            let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                            let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                            writeMultiWindowNotificationTestData([
                                "window1Id": window1.windowId.uuidString,
                                "window2Id": window2.windowId.uuidString,
                                "window2InitialSidebarSelection": "notifications",
                                "tabId1": tabId1.uuidString,
                                "tabId2": tabId2.uuidString,
                                "surfaceId1": surfaceId1.uuidString,
                                "surfaceId2": surfaceId2.uuidString,
                                "notifId1": notif1?.id.uuidString ?? "",
                                "notifId2": notif2?.id.uuidString ?? "",
                                "expectedLatestWindowId": window1.windowId.uuidString,
                                "expectedLatestTabId": tabId1.uuidString,
                            ], at: path)
                            prepareMultiWindowNotificationSourceTerminalIfNeeded(
                                at: path,
                                windowId: window1.windowId,
                                tabManager: window1.tabManager,
                                tabId: tabId1,
                                surfaceId: surfaceId1
                            )
                            publishMultiWindowNotificationSocketStateIfNeeded(at: path)
                        }
                    }
                }
            }
        }

        private func prepareMultiWindowNotificationSourceTerminalIfNeeded(
            at path: String,
            windowId: UUID,
            tabManager: TabManager,
            tabId: UUID,
            surfaceId: UUID
        ) {
            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] == "1" else { return }

            writeMultiWindowNotificationTestData([
                "sourceTerminalReady": "pending",
                "sourceTerminalFocusFailure": "",
            ], at: path)

            let deadline = Date().addingTimeInterval(8.0)

            func publish(ready: Bool, failure: String = "") {
                writeMultiWindowNotificationTestData([
                    "sourceTerminalReady": ready ? "1" : "0",
                    "sourceTerminalFocusFailure": failure,
                ], at: path)
            }

            func poll() {
                guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                    publish(ready: false, failure: "workspace_missing")
                    return
                }
                guard let terminalPanel = workspace.terminalPanel(for: surfaceId) else {
                    publish(ready: false, failure: "terminal_missing")
                    return
                }

                let isWindowFrontmost = {
                    guard let window = self.mainWindow(for: windowId) else { return false }
                    return NSApp.keyWindow === window || NSApp.mainWindow === window
                }()
                if isWindowFrontmost, terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    publish(ready: true)
                    return
                }

                guard Date() < deadline else {
                    publish(
                        ready: false,
                        failure: isWindowFrontmost ? "terminal_not_first_responder" : "window_not_frontmost"
                    )
                    return
                }

                _ = focusMainWindow(windowId: windowId)
                if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
                    tabManager.selectTab(tab)
                    tabManager.focusSurface(tabId: tabId, surfaceId: surfaceId)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    poll()
                }
            }

            poll()
        }

        private func publishMultiWindowNotificationSocketStateIfNeeded(at path: String) {
            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

            guard let config = socketListenerConfigurationIfEnabled() else {
                writeMultiWindowNotificationTestData([
                    "socketExpectedPath": env["CMUX_SOCKET_PATH"] ?? "",
                    "socketMode": "off",
                    "socketReady": "0",
                    "socketPingResponse": "",
                    "socketIsRunning": "0",
                    "socketAcceptLoopAlive": "0",
                    "socketPathMatches": "0",
                    "socketPathExists": "0",
                    "socketFailureSignals": "socket_disabled",
                ], at: path)
                return
            }

            writeMultiWindowNotificationTestData([
                "socketExpectedPath": config.path,
                "socketMode": config.mode.rawValue,
                "socketReady": "pending",
                "socketPingResponse": "",
            ], at: path)

            restartSocketListenerIfEnabled(source: "uiTest.multiWindowNotifications.setup")

            let deadline = Date().addingTimeInterval(20.0)
            func publish() {
                let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: config.path)
                let isTimedOut = Date() >= deadline
                let socketPath = config.path
                let socketMode = config.mode.rawValue
                let dataPath = path

                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let pingResponse = health.isHealthy
                        ? TerminalController.probeSocketCommand("ping", at: socketPath, timeout: 1.0)
                        : nil
                    let isReady = health.isHealthy && pingResponse == "PONG"
                    let failureSignals = {
                        var signals = health.failureSignals
                        if health.isHealthy, pingResponse != "PONG" {
                            signals.append("ping_timeout")
                        }
                        return signals.joined(separator: ",")
                    }()

                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        writeMultiWindowNotificationTestData([
                            "socketExpectedPath": socketPath,
                            "socketMode": socketMode,
                            "socketReady": isReady ? "1" : (isTimedOut ? "0" : "pending"),
                            "socketPingResponse": pingResponse ?? "",
                            "socketIsRunning": health.isRunning ? "1" : "0",
                            "socketAcceptLoopAlive": health.acceptLoopAlive ? "1" : "0",
                            "socketPathMatches": health.socketPathMatches ? "1" : "0",
                            "socketPathExists": health.socketPathExists ? "1" : "0",
                            "socketFailureSignals": failureSignals,
                        ], at: dataPath)
                        guard !isTimedOut, !isReady else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            publish()
                        }
                    }
                }
            }

            publish()
        }

        private func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
            var payload = loadMultiWindowNotificationTestData(at: path)
            for (key, value) in updates {
                payload[key] = value
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        private func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                return [:]
            }
            return object
        }

        private func recordMultiWindowNotificationFocusIfNeeded(
            windowId: UUID,
            tabId: UUID,
            surfaceId: UUID?,
            sidebarSelection: SidebarSelection
        ) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }
            let sidebarSelectionString = switch sidebarSelection {
                case .tabs: "tabs"
                case .notifications: "notifications"
            }
            writeMultiWindowNotificationTestData([
                "focusToken": UUID().uuidString,
                "focusedWindowId": windowId.uuidString,
                "focusedTabId": tabId.uuidString,
                "focusedSurfaceId": surfaceId?.uuidString ?? "",
                "focusedSidebarSelection": sidebarSelectionString,
            ], at: path)
        }
    #endif

    private func installWindowResponderSwizzles() {
        _ = Self.didInstallApplicationSendEventSwizzle
        _ = Self.didInstallWindowKeyEquivalentSwizzle
        _ = Self.didInstallWindowFirstResponderSwizzle
        _ = Self.didInstallWindowSendEventSwizzle
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                #if DEBUG
                    let phaseTotalStart = ProcessInfo.processInfo.systemUptime
                    let preludeStart = ProcessInfo.processInfo.systemUptime
                    var preludeMs: Double = 0
                    var shortcutMs: Double = 0
                    CmuxTypingTiming.logEventDelay(path: "appMonitor", event: event)
                    let shortcutMonitorTraceEnabled =
                        ProcessInfo.processInfo.environment["CMUX_SHORTCUT_MONITOR_TRACE"] == "1"
                            || UserDefaults.standard.bool(forKey: "cmuxShortcutMonitorTrace")
                    if shortcutMonitorTraceEnabled {
                        let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                        dlog(
                            "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(debugShortcutRouteSnapshot(event: event))"
                        )
                    }
                    if let probeKind = developerToolsShortcutProbeKind(event: event) {
                        logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                    }
                    preludeMs = (ProcessInfo.processInfo.systemUptime - preludeStart) * 1000.0
                    let shortcutTimingStart = CmuxTypingTiming.start()
                #endif
                let shortcutStart = ProcessInfo.processInfo.systemUptime
                let handledByShortcut = handleCustomShortcut(event: event)
                #if DEBUG
                    shortcutMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                    CmuxTypingTiming.logDuration(
                        path: "appMonitor.handleCustomShortcut",
                        startedAt: shortcutTimingStart,
                        event: event,
                        extra: "handled=\(handledByShortcut ? 1 : 0)"
                    )
                    let shortcutElapsedMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                    logSlowShortcutMonitorLatencyIfNeeded(
                        event: event,
                        handledByShortcut: handledByShortcut,
                        elapsedMs: shortcutElapsedMs
                    )
                    let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                    CmuxTypingTiming.logBreakdown(
                        path: "appMonitor.phase",
                        totalMs: totalMs,
                        event: event,
                        thresholdMs: 0.75,
                        parts: [
                            ("preludeMs", preludeMs),
                            ("shortcutMs", shortcutMs),
                        ],
                        extra: "handled=\(handledByShortcut ? 1 : 0)"
                    )
                #endif
                if handledByShortcut {
                    #if DEBUG
                        dlog("  → consumed by handleCustomShortcut")
                    #endif
                    return nil // Consume the event
                }
                return event // Pass through
            }
            handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            if clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true) {
                return nil
            }
            return event
        }
    }

    private func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
        }
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    private func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            splitButtonTooltipRefreshScheduled = false
            refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    private func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in mainWindowContexts.values {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    private func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshGhosttyGotoSplitShortcuts()
        }
    }

    private func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    private func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        let key: String
        switch trigger.tag {
            case GHOSTTY_TRIGGER_PHYSICAL:
                switch trigger.key.physical {
                    case GHOSTTY_KEY_ARROW_LEFT:
                        key = "←"
                    case GHOSTTY_KEY_ARROW_RIGHT:
                        key = "→"
                    case GHOSTTY_KEY_ARROW_UP:
                        key = "↑"
                    case GHOSTTY_KEY_ARROW_DOWN:
                        key = "↓"
                    case GHOSTTY_KEY_A: key = "a"
                    case GHOSTTY_KEY_B: key = "b"
                    case GHOSTTY_KEY_C: key = "c"
                    case GHOSTTY_KEY_D: key = "d"
                    case GHOSTTY_KEY_E: key = "e"
                    case GHOSTTY_KEY_F: key = "f"
                    case GHOSTTY_KEY_G: key = "g"
                    case GHOSTTY_KEY_H: key = "h"
                    case GHOSTTY_KEY_I: key = "i"
                    case GHOSTTY_KEY_J: key = "j"
                    case GHOSTTY_KEY_K: key = "k"
                    case GHOSTTY_KEY_L: key = "l"
                    case GHOSTTY_KEY_M: key = "m"
                    case GHOSTTY_KEY_N: key = "n"
                    case GHOSTTY_KEY_O: key = "o"
                    case GHOSTTY_KEY_P: key = "p"
                    case GHOSTTY_KEY_Q: key = "q"
                    case GHOSTTY_KEY_R: key = "r"
                    case GHOSTTY_KEY_S: key = "s"
                    case GHOSTTY_KEY_T: key = "t"
                    case GHOSTTY_KEY_U: key = "u"
                    case GHOSTTY_KEY_V: key = "v"
                    case GHOSTTY_KEY_W: key = "w"
                    case GHOSTTY_KEY_X: key = "x"
                    case GHOSTTY_KEY_Y: key = "y"
                    case GHOSTTY_KEY_Z: key = "z"
                    case GHOSTTY_KEY_DIGIT_0: key = "0"
                    case GHOSTTY_KEY_DIGIT_1: key = "1"
                    case GHOSTTY_KEY_DIGIT_2: key = "2"
                    case GHOSTTY_KEY_DIGIT_3: key = "3"
                    case GHOSTTY_KEY_DIGIT_4: key = "4"
                    case GHOSTTY_KEY_DIGIT_5: key = "5"
                    case GHOSTTY_KEY_DIGIT_6: key = "6"
                    case GHOSTTY_KEY_DIGIT_7: key = "7"
                    case GHOSTTY_KEY_DIGIT_8: key = "8"
                    case GHOSTTY_KEY_DIGIT_9: key = "9"
                    case GHOSTTY_KEY_BRACKET_LEFT: key = "["
                    case GHOSTTY_KEY_BRACKET_RIGHT: key = "]"
                    case GHOSTTY_KEY_MINUS: key = "-"
                    case GHOSTTY_KEY_EQUAL: key = "="
                    case GHOSTTY_KEY_COMMA: key = ","
                    case GHOSTTY_KEY_PERIOD: key = "."
                    case GHOSTTY_KEY_SLASH: key = "/"
                    case GHOSTTY_KEY_SEMICOLON: key = ";"
                    case GHOSTTY_KEY_QUOTE: key = "'"
                    case GHOSTTY_KEY_BACKQUOTE: key = "`"
                    case GHOSTTY_KEY_BACKSLASH: key = "\\"
                    default:
                        return nil
                }

            case GHOSTTY_TRIGGER_UNICODE:
                guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
                key = String(Character(scalar)).lowercased()

            case GHOSTTY_TRIGGER_CATCH_ALL:
                return nil

            default:
                return nil
        }

        let mods = trigger.mods.rawValue
        let command = (mods & GHOSTTY_MODS_SUPER.rawValue) != 0
        let shift = (mods & GHOSTTY_MODS_SHIFT.rawValue) != 0
        let option = (mods & GHOSTTY_MODS_ALT.rawValue) != 0
        let control = (mods & GHOSTTY_MODS_CTRL.rawValue) != 0

        // Ignore bogus empty triggers.
        if key.isEmpty || (!command && !shift && !option && !control) {
            return nil
        }

        return StoredShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    private func handleQuitShortcutWarning() -> Bool {
        if !QuitWarningSettings.isEnabled() {
            NSApp.terminate(nil)
            return true
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.quitCmux.title", defaultValue: "Quit cmux?")
        alert.informativeText = String(localized: "dialog.quitCmux.message", defaultValue: "This will close all windows and workspaces.")
        alert.addButton(withTitle: String(localized: "dialog.quitCmux.quit", defaultValue: "Quit"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "dialog.dontWarnCmdQ", defaultValue: "Don't warn again for Cmd+Q")

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            QuitWarningSettings.setEnabled(false)
        }

        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        return true
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        // `charactersIgnoringModifiers` can be nil for some synthetic NSEvents and certain special keys.
        // Treat nil as "" and rely on keyCode/layout-aware fallback logic where needed.
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isControlOnly = hasControl && !hasCommand && !hasOption
        let controlDChar = chars == "d" || event.characters == "\u{04}"
        let isControlD = isControlOnly && (controlDChar || event.keyCode == 2)
        #if DEBUG
            if isControlD {
                writeChildExitKeyboardProbe(
                    [
                        "probeAppShortcutCharsHex": childExitKeyboardProbeHex(event.characters),
                        "probeAppShortcutCharsIgnoringHex": childExitKeyboardProbeHex(event.charactersIgnoringModifiers),
                        "probeAppShortcutKeyCode": String(event.keyCode),
                        "probeAppShortcutModsRaw": String(event.modifierFlags.rawValue),
                    ],
                    increments: ["probeAppShortcutCtrlDSeenCount": 1]
                )
            }
        #endif

        // Don't steal shortcuts from close-confirmation alerts. Keep standard alert key
        // equivalents working and avoid surprising actions while the confirmation is up.
        let closeConfirmationTitles = [
            String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?"),
            String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
            String(localized: "dialog.closeOtherTabs.title", defaultValue: "Close other tabs?"),
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?"),
        ]
        let closeConfirmationPanel = NSApp.windows
            .compactMap { $0 as? NSPanel }
            .first { panel in
                guard panel.isVisible, let root = panel.contentView else { return false }
                return closeConfirmationTitles.contains { title in
                    findStaticText(in: root, equals: title)
                }
            }
        if let closeConfirmationPanel {
            // Special-case: Cmd+D should confirm destructive close on alerts.
            // XCUITest key events often hit the app-level local monitor first, so forward the key
            // equivalent to the alert panel explicitly.
            if matchShortcut(
                event: event,
                shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            ),
                let root = closeConfirmationPanel.contentView,
                let closeButton = findButton(
                    in: root,
                    titled: String(localized: "common.close", defaultValue: "Close")
                )
            {
                closeButton.performClick(nil)
                return true
            }
            return false
        }

        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil {
            return false
        }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        let commandPaletteTargetWindow = commandPaletteWindowForShortcutEvent(event)
        let commandPaletteShortcutWindow = shouldHandleCommandPaletteShortcutEvent(
            event,
            paletteWindow: commandPaletteTargetWindow
        ) ? commandPaletteTargetWindow : nil
        let commandPaletteVisibleInTargetWindow = commandPaletteShortcutWindow.map {
            isCommandPaletteVisible(for: $0)
        } ?? false
        let commandPalettePendingOpenInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPalettePendingOpen(for: $0)
        } ?? false
        let commandPaletteOverlayVisibleInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteOverlayPresented(in: $0)
        } ?? false
        let commandPaletteResponderActiveInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteResponderActive(in: $0)
        } ?? false
        let commandPaletteInteractiveInTargetWindow =
            commandPaletteVisibleInTargetWindow
                || commandPaletteOverlayVisibleInTargetWindow
                || commandPaletteResponderActiveInTargetWindow
        let commandPaletteEffectiveInTargetWindow =
            commandPaletteInteractiveInTargetWindow
                || commandPalettePendingOpenInTargetWindow

        if normalizedFlags.isEmpty, event.keyCode == 53 {
            let activePaletteWindow = activeCommandPaletteWindow()
            let escapePaletteWindow: NSWindow? = {
                if let targetWindow = commandPaletteTargetWindow {
                    guard commandPaletteEffectiveInTargetWindow else {
                        return nil
                    }
                    return targetWindow
                }
                return activePaletteWindow
            }()
            #if DEBUG
                dlog(
                    "shortcut.escape route target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                        "active={\(debugWindowToken(activePaletteWindow))} " +
                        "visibleTarget=\(commandPaletteVisibleInTargetWindow ? 1 : 0) " +
                        "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                        "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                        "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                        "effectiveTarget=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                        "\(debugShortcutRouteSnapshot(event: event))"
                )
                if commandPaletteTargetWindow != nil,
                   !commandPaletteVisibleInTargetWindow,
                   !commandPalettePendingOpenInTargetWindow,
                   commandPaletteOverlayVisibleInTargetWindow || commandPaletteResponderActiveInTargetWindow
                {
                    dlog(
                        "shortcut.escape stateMismatch target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                            "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                            "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0)"
                    )
                }
            #endif
            if let paletteWindow = escapePaletteWindow,
               isCommandPaletteEffectivelyVisible(in: paletteWindow)
            {
                if commandPaletteMarkedTextInput(in: paletteWindow) != nil {
                    #if DEBUG
                        dlog(
                            "shortcut.escape imeMarkedTextBypass consumed=0 target={\(debugWindowToken(paletteWindow))}"
                        )
                    #endif
                    return false
                }
                clearCommandPalettePendingOpen(for: paletteWindow)
                beginCommandPaletteEscapeSuppression(for: paletteWindow)
                NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: paletteWindow)
                #if DEBUG
                    dlog("shortcut.escape paletteDismiss consumed=1 target={\(debugWindowToken(paletteWindow))}")
                #endif
                return true
            }
            let suppressionWindow = commandPaletteTargetWindow
                ?? event.window
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
            if shouldConsumeSuppressedEscape(event: event, window: suppressionWindow) {
                #if DEBUG
                    dlog(
                        "shortcut.escape suppressionConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                            "repeat=\(event.isARepeat ? 1 : 0)"
                    )
                #endif
                return true
            }
            if let requestAge = recentCommandPaletteRequestAge(for: suppressionWindow) {
                beginCommandPaletteEscapeSuppression(for: suppressionWindow)
                #if DEBUG
                    dlog(
                        "shortcut.escape requestGraceConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                            "ageMs=\(Int(requestAge * 1000)) repeat=\(event.isARepeat ? 1 : 0)"
                    )
                #endif
                return true
            }
            #if DEBUG
                dlog(
                    "shortcut.escape paletteDismiss consumed=0 target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                        "active={\(debugWindowToken(activePaletteWindow))}"
                )
            #endif
        }

        if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
            flags: event.modifierFlags,
            chars: chars,
            keyCode: event.keyCode
        ),
            commandPaletteInteractiveInTargetWindow,
            let paletteWindow = commandPaletteShortcutWindow
        {
            NotificationCenter.default.post(
                name: .commandPaletteMoveSelection,
                object: paletteWindow,
                userInfo: ["delta": delta]
            )
            return true
        }

        if commandPaletteInteractiveInTargetWindow,
           let paletteWindow = commandPaletteShortcutWindow
        {
            let paletteFieldEditorHasMarkedText = commandPaletteFieldEditorHasMarkedText(in: paletteWindow)
            if normalizedFlags.isEmpty, event.keyCode == 53 {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: paletteWindow)
                return true
            }

            if shouldSubmitCommandPaletteWithReturn(
                keyCode: event.keyCode,
                flags: event.modifierFlags
            ) {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteSubmitRequested, object: paletteWindow)
                return true
            }
        }

        // Guard against stale browserAddressBarFocusedPanelId after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserAddressBarFocusedPanelId != nil,
           cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder) != nil
        {
            #if DEBUG
                let stalePanelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                dlog(
                    "browser.focus.addressBar.staleClear panel=\(stalePanelToken) " +
                        "reason=terminal_first_responder fr=\(firstResponderType)"
                )
            #endif
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
        }

        // Keep Cmd+P/Cmd+N inside the focused browser omnibar for Chrome-like
        // suggestion navigation, and avoid opening command palette switcher.
        // Scope the omnibar check to the shortcut's routed window context so a
        // focused omnibar in another window does not suppress Cmd+P here.
        let hasFocusedAddressBarInShortcutContext = focusedBrowserAddressBarPanelIdForShortcutEvent(event) != nil
        let isCommandShiftP = matchShortcut(
            event: event,
            shortcut: StoredShortcut(key: "p", command: true, shift: true, option: false, control: false)
        )
        if isCommandShiftP {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.cmdShiftP")
            return true
        }

        let isCommandP = !hasFocusedAddressBarInShortcutContext
            && matchShortcut(
                event: event,
                shortcut: StoredShortcut(key: "p", command: true, shift: false, option: false, control: false)
            )
        if isCommandP {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.cmdP")
            return true
        }

        if shouldConsumeShortcutWhileCommandPaletteVisible(
            isCommandPaletteVisible: commandPaletteEffectiveInTargetWindow,
            normalizedFlags: normalizedFlags,
            chars: chars,
            keyCode: event.keyCode
        ) {
            return true
        }

        if matchShortcut(
            event: event,
            shortcut: StoredShortcut(key: "q", command: true, shift: false, option: false, control: false)
        ) {
            return handleQuitShortcutWarning()
        }
        if matchShortcut(
            event: event,
            shortcut: StoredShortcut(key: ",", command: true, shift: true, option: false, control: false)
        ) {
            GhosttyApp.shared.reloadConfiguration(source: "shortcut.cmd_shift_comma")
            return true
        }

        if shouldToggleMainWindowFullScreenForCommandControlFShortcut(
            flags: event.modifierFlags,
            chars: chars,
            keyCode: event.keyCode
        ) {
            guard let targetWindow = mainWindowForShortcutEvent(event) else {
                return false
            }
            targetWindow.toggleFullScreen(nil)
            return true
        }

        // When the terminal has active IME composition (e.g. Korean, Japanese, Chinese
        // input), don't intercept non-Cmd key events — let them flow through to the
        // input method. Cmd-based shortcuts (Cmd+T, Cmd+Shift+L, etc.) should still
        // work during composition since Cmd is never part of IME input sequences.
        if !normalizedFlags.contains(.command),
           let ghosttyView = cmuxOwningGhosttyView(for: NSApp.keyWindow?.firstResponder),
           ghosttyView.hasMarkedText()
        {
            return false
        }

        // When the notifications popover is open, Escape should dismiss it immediately.
        if flags.isEmpty, event.keyCode == 53, titlebarAccessoryController.dismissNotificationsPopoverIfShown() {
            return true
        }

        // When the notifications popover is showing an empty state, consume plain typing
        // so key presses do not leak through into the focused terminal.
        if flags.isDisjoint(with: [.command, .control, .option]),
           titlebarAccessoryController.isNotificationsPopoverShown(),
           notificationStore?.notifications.isEmpty ?? false
        {
            return true
        }

        let hasEventWindowContext = shortcutEventHasAddressableWindow(event)
        let didSynchronizeShortcutContext = synchronizeShortcutRoutingContext(event: event)
        if hasEventWindowContext && !didSynchronizeShortcutContext {
            #if DEBUG
                dlog("handleCustomShortcut: unresolved event window context; bypassing app shortcut handling")
            #endif
            return false
        }

        // Keep keyboard routing deterministic after split close/reparent transitions:
        // before processing shortcuts, converge first responder with the focused terminal panel.
        if isControlD {
            #if DEBUG
                let selected = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
                let focused = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
                let frType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                dlog("shortcut.ctrlD stage=preReconcile selected=\(selected) focused=\(focused) fr=\(frType)")
            #endif
            tabManager?.reconcileFocusedPanelFromFirstResponderForKeyboard()
            #if DEBUG
                let frAfterType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                dlog("shortcut.ctrlD stage=postReconcile fr=\(frAfterType)")
                writeChildExitKeyboardProbe([:], increments: ["probeAppShortcutCtrlDPassedCount": 1])
            #endif
            // Ctrl+D belongs to the focused terminal surface; never treat it as an app shortcut.
            return false
        }

        // Chrome-like omnibar navigation while holding Cmd+N / Ctrl+N / Cmd+P / Ctrl+P.
        if let delta = commandOmnibarSelectionDelta(flags: flags, chars: chars) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: event.keyCode, delta: delta)
            return true
        }

        if let delta = browserOmnibarSelectionDeltaForArrowNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        ) {
            dispatchBrowserOmnibarSelectionMove(delta: delta)
            return true
        }

        // Fast path for normal typing and terminal navigation keys (for example Up-arrow
        // history): after command-palette/notification handling and browser omnibar
        // arrow navigation above, plain key events have no app-level shortcut behavior.
        if normalizedFlags.isEmpty {
            return false
        }

        // Let omnibar-local Emacs navigation (Cmd/Ctrl+N/P) win while the browser
        // address bar is focused. Without this, app-level Cmd+N can steal focus.
        if shouldBypassAppShortcutForFocusedBrowserAddressBar(flags: flags, chars: chars) {
            return false
        }

        // Primary UI shortcuts
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleSidebar)) {
            _ = toggleSidebarInActiveMainWindow()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newTab)) {
            #if DEBUG
                dlog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
            #endif
            // Cmd+N semantics:
            // - If there are no main windows, create a new window.
            // - Otherwise, create a new workspace in the active window.
            if mainWindowContexts.isEmpty {
                #if DEBUG
                    logWorkspaceCreationRouting(
                        phase: "fallback_new_window",
                        source: "shortcut.cmdN",
                        reason: "no_main_windows",
                        event: event,
                        chosenContext: nil
                    )
                #endif
                openNewMainWindow(nil)
            } else if addWorkspaceInPreferredMainWindow(event: event, debugSource: "shortcut.cmdN") == nil {
                #if DEBUG
                    logWorkspaceCreationRouting(
                        phase: "fallback_new_window",
                        source: "shortcut.cmdN",
                        reason: "workspace_creation_returned_nil",
                        event: event,
                        chosenContext: nil
                    )
                #endif
                openNewMainWindow(nil)
            }
            return true
        }

        // New Window: Cmd+Shift+N
        // Handled here instead of relying on SwiftUI's CommandGroup menu item because
        // after a browser panel has been shown, SwiftUI's menu dispatch can silently
        // consume the key equivalent without firing the action closure.
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newWindow)) {
            openNewMainWindow(nil)
            return true
        }

        // Check Show Notifications shortcut
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showNotifications)) {
            toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .sendFeedback)) {
            guard let targetContext = preferredMainWindowContextForShortcuts(event: event),
                  let targetWindow = targetContext.window ?? windowForMainWindowId(targetContext.windowId)
            else {
                return false
            }
            setActiveMainWindow(targetWindow)
            bringToFront(targetWindow)
            NotificationCenter.default.post(name: .feedbackComposerRequested, object: targetWindow)
            return true
        }

        // Check Jump to Unread shortcut
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .jumpToUnread)) {
            #if DEBUG
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                    writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
                }
            #endif
            jumpToLatestUnread()
            return true
        }

        // Flash the currently focused panel so the user can visually confirm focus.
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .triggerFlash)) {
            tabManager?.triggerFocusFlash()
            return true
        }

        // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .nextSurface)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .prevSurface)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleTerminalCopyMode)) {
            let handled = tabManager?.toggleFocusedTerminalCopyMode() ?? false
            #if DEBUG
                dlog(
                    "shortcut.action name=toggleTerminalCopyMode handled=\(handled ? 1 : 0) " +
                        "\(debugShortcutRouteSnapshot(event: event))"
                )
            #endif
            // Only consume when a focused terminal actually handled the toggle.
            // Otherwise allow the event to continue through the responder chain.
            return handled
        }

        // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .nextSidebarTab)) {
            #if DEBUG
                let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                dlog(
                    "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
                )
            #endif
            tabManager?.selectNextTab()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .prevSidebarTab)) {
            #if DEBUG
                let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                dlog(
                    "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
                )
            #endif
            tabManager?.selectPreviousTab()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace)) {
            return requestRenameWorkspaceViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            )
        }

        if matchShortcut(
            event: event,
            shortcut: StoredShortcut(key: "t", command: true, shift: false, option: true, control: false)
        ) {
            if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               targetWindow.identifier?.rawValue == "cmux.settings"
            {
                targetWindow.performClose(nil)
            } else {
                let responder = event.window?.firstResponder
                    ?? NSApp.keyWindow?.firstResponder
                    ?? NSApp.mainWindow?.firstResponder
                if let ghosttyView = cmuxOwningGhosttyView(for: responder),
                   let workspaceId = ghosttyView.tabId,
                   let manager = tabManagerFor(tabId: workspaceId) ?? tabManager
                {
                    manager.closeOtherTabsInFocusedPaneWithConfirmation()
                } else {
                    tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
                }
            }
            return true
        }

        // Cmd+W must close the focused panel even if first-responder momentarily lags on a
        // browser NSTextView during split focus transitions.
        if matchShortcut(
            event: event,
            shortcut: StoredShortcut(key: "w", command: true, shift: false, option: false, control: false)
        ) {
            // Browser popup windows primarily intercept Cmd+W in BrowserPopupPanel.
            // This AppDelegate path is a fallback for cases where AppKit routes the
            // event through the global shortcut handler first.
            if let targetWindow = [NSApp.keyWindow, event.window]
                .compactMap({ $0 })
                .first(where: { $0.identifier?.rawValue == "cmux.browser-popup" })
            {
                #if DEBUG
                    dlog("shortcut.cmdW route=browserPopup")
                #endif
                targetWindow.performClose(nil)
                return true
            } else if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
                      cmuxWindowShouldOwnCloseShortcut(targetWindow)
            {
                targetWindow.performClose(nil)
            } else {
                let responder = event.window?.firstResponder
                    ?? NSApp.keyWindow?.firstResponder
                    ?? NSApp.mainWindow?.firstResponder
                if let ghosttyView = cmuxOwningGhosttyView(for: responder),
                   let workspaceId = ghosttyView.tabId,
                   let panelId = ghosttyView.terminalSurface?.id,
                   let manager = tabManagerFor(tabId: workspaceId) ?? tabManager
                {
                    #if DEBUG
                        dlog(
                            "shortcut.cmdW route=ghostty workspace=\(workspaceId.uuidString.prefix(5)) " +
                                "panel=\(panelId.uuidString.prefix(5)) selected=\(manager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                        )
                    #endif
                    manager.closePanelWithConfirmation(tabId: workspaceId, surfaceId: panelId)
                } else {
                    #if DEBUG
                        dlog("shortcut.cmdW route=focusedPanelFallback")
                    #endif
                    tabManager?.closeCurrentPanelWithConfirmation()
                }
            }
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .closeWorkspace)) {
            tabManager?.closeCurrentWorkspaceWithConfirmation()
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .closeWindow)) {
            guard let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return true
            }
            closeWindowWithConfirmation(targetWindow)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .renameTab)) {
            // Keep Cmd+R browser reload behavior when a browser panel is focused.
            if tabManager?.focusedBrowserPanel != nil {
                return false
            }
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            requestCommandPaletteRenameTab(preferredWindow: targetWindow, source: "shortcut.renameTab")
            return true
        }

        // Numeric shortcuts for specific sidebar tabs: Cmd+1-9 (9 = last workspace)
        if flags == [.command],
           let manager = tabManager,
           let num = Int(chars),
           let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forCommandDigit: num, workspaceCount: manager.tabs.count)
        {
            #if DEBUG
                dlog(
                    "shortcut.action name=workspaceDigit digit=\(num) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
                )
            #endif
            manager.selectTab(at: targetIndex)
            return true
        }

        // Numeric shortcuts for surfaces within pane: Ctrl+1-9 (9 = last)
        if flags == [.control] {
            if let num = Int(chars), num >= 1, num <= 9 {
                if num == 9 {
                    tabManager?.selectLastSurface()
                } else {
                    tabManager?.selectSurface(at: num - 1)
                }
                return true
            }
        }

        // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusLeft),
            arrowGlyph: "←",
            arrowKeyCode: 123
        ) || (ghosttyGotoSplitLeftShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "←", arrowKeyCode: 123) } ?? false) {
            tabManager?.movePaneFocus(direction: .left)
            #if DEBUG
                recordGotoSplitMoveIfNeeded(direction: .left)
            #endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusRight),
            arrowGlyph: "→",
            arrowKeyCode: 124
        ) || (ghosttyGotoSplitRightShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "→", arrowKeyCode: 124) } ?? false) {
            tabManager?.movePaneFocus(direction: .right)
            #if DEBUG
                recordGotoSplitMoveIfNeeded(direction: .right)
            #endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusUp),
            arrowGlyph: "↑",
            arrowKeyCode: 126
        ) || (ghosttyGotoSplitUpShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↑", arrowKeyCode: 126) } ?? false) {
            tabManager?.movePaneFocus(direction: .up)
            #if DEBUG
                recordGotoSplitMoveIfNeeded(direction: .up)
            #endif
            return true
        }
        if matchDirectionalShortcut(
            event: event,
            shortcut: KeyboardShortcutSettings.shortcut(for: .focusDown),
            arrowGlyph: "↓",
            arrowKeyCode: 125
        ) || (ghosttyGotoSplitDownShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↓", arrowKeyCode: 125) } ?? false) {
            tabManager?.movePaneFocus(direction: .down)
            #if DEBUG
                recordGotoSplitMoveIfNeeded(direction: .down)
            #endif
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleSplitZoom)) {
            _ = tabManager?.toggleFocusedSplitZoom()
            #if DEBUG
                recordGotoSplitZoomIfNeeded()
            #endif
            return true
        }

        // Split actions: Cmd+D / Cmd+Shift+D
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitRight)) {
            #if DEBUG
                dlog("shortcut.action name=splitRight \(debugShortcutRouteSnapshot(event: event))")
            #endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .right) {
                return true
            }
            _ = performSplitShortcut(direction: .right)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitDown)) {
            #if DEBUG
                dlog("shortcut.action name=splitDown \(debugShortcutRouteSnapshot(event: event))")
            #endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .down) {
                return true
            }
            _ = performSplitShortcut(direction: .down)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitBrowserRight)) {
            #if DEBUG
                dlog("shortcut.action name=splitBrowserRight \(debugShortcutRouteSnapshot(event: event))")
            #endif
            _ = performBrowserSplitShortcut(direction: .right)
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .splitBrowserDown)) {
            #if DEBUG
                dlog("shortcut.action name=splitBrowserDown \(debugShortcutRouteSnapshot(event: event))")
            #endif
            _ = performBrowserSplitShortcut(direction: .down)
            return true
        }

        // Surface navigation (legacy Ctrl+Tab support)
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .newSurface)) {
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .openBrowser)) {
            _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
            return true
        }

        // Safari defaults:
        // - Option+Command+I => Show/Toggle Web Inspector
        // - Option+Command+C => Show JavaScript Console
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            #if DEBUG
                logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
            #endif
            let didHandle = tabManager?.toggleDeveloperToolsFocusedBrowser() ?? false
            #if DEBUG
                logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
                DispatchQueue.main.async { [weak self] in
                    self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
                }
            #endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            #if DEBUG
                logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
            #endif
            let didHandle = tabManager?.showJavaScriptConsoleFocusedBrowser() ?? false
            #if DEBUG
                logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
                DispatchQueue.main.async { [weak self] in
                    self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
                }
            #endif
            if !didHandle { NSSound.beep() }
            return true
        }

        // Focus browser address bar: Cmd+L
        if matchShortcut(
            event: event,
            shortcut: StoredShortcut(key: "l", command: true, shift: false, option: false, control: false)
        ) {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let browserAddressBarFocusedPanelId,
               focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId)
            {
                return true
            }

            if openBrowserAndFocusAddressBar(insertAtEnd: true) != nil {
                return true
            }
        }

        #if DEBUG
            logBrowserZoomShortcutTrace(stage: "probe", event: event, flags: flags, chars: chars)
        #endif
        let zoomAction = browserZoomShortcutAction(
            flags: flags,
            chars: chars,
            keyCode: event.keyCode,
            literalChars: event.characters
        )
        #if DEBUG
            logBrowserZoomShortcutTrace(stage: "match", event: event, flags: flags, chars: chars, action: zoomAction)
        #endif
        if let action = zoomAction, let manager = tabManager {
            let handled: Bool = switch action {
                case .zoomIn:
                    manager.zoomInFocusedBrowser()
                case .zoomOut:
                    manager.zoomOutFocusedBrowser()
                case .reset:
                    manager.resetZoomFocusedBrowser()
            }
            #if DEBUG
                logBrowserZoomShortcutTrace(
                    stage: "dispatch",
                    event: event,
                    flags: flags,
                    chars: chars,
                    action: action,
                    handled: handled
                )
            #endif
            return handled
        }
        #if DEBUG
            if zoomAction != nil, tabManager == nil {
                logBrowserZoomShortcutTrace(
                    stage: "dispatch.noManager",
                    event: event,
                    flags: flags,
                    chars: chars,
                    action: zoomAction,
                    handled: false
                )
            }
        #endif

        return false
    }

    private func shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: SplitDirection) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId)
        else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = hostedView.window != nil
        let firstResponderIsWindow = NSApp.keyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        tabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

        #if DEBUG
            let directionLabel = switch direction {
                case .left: "left"
                case .right: "right"
                case .up: "up"
                case .down: "down"
            }
            let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            dlog(
                "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
                    "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
                    "attached=\(hostedAttachedToWindow ? 1 : 0) " +
                    "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
            )
        #endif
        return true
    }

    #if DEBUG
        private func logBrowserZoomShortcutTrace(
            stage: String,
            event: NSEvent,
            flags: NSEvent.ModifierFlags,
            chars: String,
            action: BrowserZoomShortcutAction? = nil,
            handled: Bool? = nil
        ) {
            guard browserZoomShortcutTraceCandidate(
                flags: flags,
                chars: chars,
                keyCode: event.keyCode,
                literalChars: event.characters
            ) else {
                return
            }

            let keyWindow = NSApp.keyWindow
            let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let panel = tabManager?.focusedBrowserPanel
            let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
            let panelZoom = panel?.webView.pageZoom ?? -1
            var line =
                "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
                "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
                "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
                "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
                "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
            if let handled {
                line += " handled=\(handled ? 1 : 0)"
            }
            dlog(line)
        }

        private func browserFocusStateSnapshot() -> String {
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let addressBar = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
            let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "selected=\(selected) focused=\(focused) addr=\(addressBar) keyWin=\(keyWindow) fr=\(firstResponderType)"
        }

        private func redactedDebugURL(_ url: URL?) -> String {
            guard let url else { return "nil" }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return "<invalid>"
            }
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string ?? "<redacted>"
        }
    #endif

    @discardableResult
    private func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId)
        else {
            #if DEBUG
                dlog(
                    "browser.focus.addressBar.route panel=\(panelId.uuidString.prefix(5)) " +
                        "result=miss \(browserFocusStateSnapshot())"
                )
            #endif
            return false
        }
        #if DEBUG
            dlog(
                "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
                    "workspace=\(workspace.id.uuidString.prefix(5)) result=hit \(browserFocusStateSnapshot())"
            )
        #endif
        workspace.focusPanel(panel.id)
        #if DEBUG
            let focusedAfter = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
                    "workspace=\(workspace.id.uuidString.prefix(5)) focusedAfter=\(focusedAfter)"
            )
        #endif
        focusBrowserAddressBar(in: panel)
        return true
    }

    private func focusBrowserAddressBar(in panel: BrowserPanel) {
        #if DEBUG
            let requestId = panel.requestAddressBarFocus()
            dlog(
                "browser.focus.addressBar.request panel=\(panel.id.uuidString.prefix(5)) " +
                    "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
            )
        #else
            _ = panel.requestAddressBarFocus()
        #endif
        browserAddressBarFocusedPanelId = panel.id
        #if DEBUG
            dlog(
                "browser.focus.addressBar.sticky panel=\(panel.id.uuidString.prefix(5)) " +
                    "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
            )
        #endif
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        #if DEBUG
            dlog(
                "browser.focus.addressBar.notify panel=\(panel.id.uuidString.prefix(5)) " +
                    "request=\(requestId.uuidString.prefix(8))"
            )
        #endif
    }

    private func focusedBrowserAddressBarPanelIdForShortcutEvent(_ event: NSEvent) -> UUID? {
        guard let panelId = browserAddressBarFocusedPanelId else { return nil }

        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
            #if DEBUG
                dlog(
                    "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                        "accepted=0 reason=no_context event=\(NSWindow.keyDescription(event))"
                )
            #endif
            return nil
        }

        guard let workspace = context.tabManager.selectedWorkspace else {
            #if DEBUG
                dlog(
                    "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                        "accepted=0 reason=no_workspace event=\(NSWindow.keyDescription(event))"
                )
            #endif
            return nil
        }

        guard workspace.browserPanel(for: panelId) != nil else {
            #if DEBUG
                dlog(
                    "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                        "accepted=0 reason=panel_not_in_workspace workspace=\(workspace.id.uuidString.prefix(5)) " +
                        "event=\(NSWindow.keyDescription(event))"
                )
            #endif
            return nil
        }

        #if DEBUG
            dlog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                    "accepted=1 workspace=\(workspace.id.uuidString.prefix(5)) event=\(NSWindow.keyDescription(event))"
            )
        #endif
        return panelId
    }

    private func shouldBypassAppShortcutForFocusedBrowserAddressBar(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Bool {
        guard browserAddressBarFocusedPanelId != nil else { return false }
        let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
        let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
        guard isCommandOrControlOnly else { return false }
        let shouldBypass = chars == "n" || chars == "p"
        #if DEBUG
            if shouldBypass {
                let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                dlog(
                    "browser.focus.addressBar.shortcutBypass panel=\(panelToken) " +
                        "chars=\(chars) flags=\(normalizedFlags.rawValue)"
                )
            }
        #endif
        return shouldBypass
    }

    private func commandOmnibarSelectionDelta(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        browserOmnibarSelectionDeltaForCommandNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: flags,
            chars: chars
        )
    }

    private func dispatchBrowserOmnibarSelectionMove(delta: Int) {
        guard delta != 0 else { return }
        guard let panelId = browserAddressBarFocusedPanelId else { return }
        #if DEBUG
            dlog(
                "browser.focus.omnibar.selectionMove panel=\(panelId.uuidString.prefix(5)) " +
                    "delta=\(delta) repeatKey=\(browserOmnibarRepeatKeyCode.map(String.init) ?? "nil")"
            )
        #endif
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    private func startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }
        guard browserAddressBarFocusedPanelId != nil else {
            #if DEBUG
                dlog(
                    "browser.focus.omnibar.repeat.start key=\(keyCode) delta=\(delta) " +
                        "result=skip_no_focused_address_bar"
                )
            #endif
            return
        }

        if browserOmnibarRepeatKeyCode == keyCode, browserOmnibarRepeatDelta == delta {
            #if DEBUG
                let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                dlog(
                    "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
                        "key=\(keyCode) delta=\(delta) result=reuse"
                )
            #endif
            return
        }

        stopBrowserOmnibarSelectionRepeat()
        browserOmnibarRepeatKeyCode = keyCode
        browserOmnibarRepeatDelta = delta
        #if DEBUG
            let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.omnibar.repeat.start panel=\(panelToken) " +
                    "key=\(keyCode) delta=\(delta) result=armed"
            )
        #endif

        let start = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    private func scheduleBrowserOmnibarSelectionRepeatTick() {
        browserOmnibarRepeatStartWorkItem = nil
        guard browserAddressBarFocusedPanelId != nil else {
            #if DEBUG
                dlog("browser.focus.omnibar.repeat.tick result=stop_no_focused_address_bar")
            #endif
            stopBrowserOmnibarSelectionRepeat()
            return
        }
        guard browserOmnibarRepeatKeyCode != nil else { return }

        #if DEBUG
            let panelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "browser.focus.omnibar.repeat.tick panel=\(panelToken) " +
                    "delta=\(browserOmnibarRepeatDelta)"
            )
        #endif
        dispatchBrowserOmnibarSelectionMove(delta: browserOmnibarRepeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    private func stopBrowserOmnibarSelectionRepeat() {
        #if DEBUG
            let previousKeyCode = browserOmnibarRepeatKeyCode
            let previousDelta = browserOmnibarRepeatDelta
        #endif
        browserOmnibarRepeatStartWorkItem?.cancel()
        browserOmnibarRepeatTickWorkItem?.cancel()
        browserOmnibarRepeatStartWorkItem = nil
        browserOmnibarRepeatTickWorkItem = nil
        browserOmnibarRepeatKeyCode = nil
        browserOmnibarRepeatDelta = 0
        #if DEBUG
            if previousKeyCode != nil || previousDelta != 0 {
                dlog(
                    "browser.focus.omnibar.repeat.stop key=\(previousKeyCode.map(String.init) ?? "nil") " +
                        "delta=\(previousDelta)"
                )
            }
        #endif
    }

    private func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard browserOmnibarRepeatKeyCode != nil else { return }

        switch event.type {
            case .keyUp:
                if event.keyCode == browserOmnibarRepeatKeyCode {
                    #if DEBUG
                        dlog(
                            "browser.focus.omnibar.repeat.lifecycle event=keyUp key=\(event.keyCode) " +
                                "action=stop"
                        )
                    #endif
                    stopBrowserOmnibarSelectionRepeat()
                }

            case .flagsChanged:
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if !flags.contains(.command) {
                    #if DEBUG
                        dlog(
                            "browser.focus.omnibar.repeat.lifecycle event=flagsChanged " +
                                "flags=\(flags.rawValue) action=stop"
                        )
                    #endif
                    stopBrowserOmnibarSelectionRepeat()
                }

            default:
                break
        }
    }

    private func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        let responderType = String(describing: type(of: responder))
        if responderType.contains("WKInspector") {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if String(describing: type(of: current)).contains("WKInspector") {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

    #if DEBUG
        private func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
            if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
                return "toggle.configured"
            }
            if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
                return "console.configured"
            }

            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .option] {
                if chars == "i" || event.keyCode == 34 {
                    return "toggle.literal"
                }
                if chars == "c" || event.keyCode == 8 {
                    return "console.literal"
                }
            }
            return nil
        }

        private func logDeveloperToolsShortcutSnapshot(
            phase: String,
            event: NSEvent? = nil,
            didHandle: Bool? = nil
        ) {
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
            if let browser = tabManager?.focusedBrowserPanel {
                var line =
                    "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                    "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                    "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
                if let didHandle {
                    line += " handled=\(didHandle ? 1 : 0)"
                }
                dlog(line)
                return
            }
            var line =
                "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
                "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            dlog(line)
        }
    #endif

    private func prepareFocusedBrowserDevToolsForSplit(directionLabel: String) {
        guard let browser = tabManager?.focusedBrowserPanel else { return }
        guard browser.shouldPreserveWebViewAttachmentDuringTransientHide() else { return }
        guard let keyWindow = NSApp.keyWindow else { return }
        guard isLikelyWebInspectorResponder(keyWindow.firstResponder) else { return }

        let beforeResponder = keyWindow.firstResponder
        let movedToWebView = keyWindow.makeFirstResponder(browser.webView)
        let movedToNil = movedToWebView ? false : keyWindow.makeFirstResponder(nil)

        #if DEBUG
            let beforeType = beforeResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let beforePtr = beforeResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let afterResponder = keyWindow.firstResponder
            let afterType = afterResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let afterPtr = afterResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            dlog(
                "split.shortcut inspector.preflight dir=\(directionLabel) panel=\(browser.id.uuidString.prefix(5)) " +
                    "before=\(beforeType)@\(beforePtr) after=\(afterType)@\(afterPtr) " +
                    "moveWeb=\(movedToWebView ? 1 : 0) moveNil=\(movedToNil ? 1 : 0) \(browser.debugDeveloperToolsStateSummary())"
            )
        #endif
    }

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    private func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    /// Match a shortcut against an event, handling normal keys.
    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        // Some keys can include extra flags (e.g. .function) depending on the responder chain.
        // Strip those for consistent matching across first responders (terminal, WebKit, etc).
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == shortcut.modifierFlags else { return false }

        let shortcutKey = shortcut.key.lowercased()
        if shortcutKey == "\r" {
            return event.keyCode == 36 || event.keyCode == 76
        }

        let eventCharsIgnoringModifiers = event.charactersIgnoringModifiers
        if shortcutCharacterMatches(
            eventCharacter: eventCharsIgnoringModifiers,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: event.keyCode
        ) {
            return true
        }

        // For command-based shortcuts, trust AppKit's layout-aware characters when present.
        // Keep this strict for letter shortcuts to avoid physical-key collisions across layouts,
        // while still allowing keyCode fallback for digit/punctuation shortcuts on non-US layouts.
        let hasEventChars = !(eventCharsIgnoringModifiers?.isEmpty ?? true)
        if hasEventChars,
           flags.contains(.command),
           !flags.contains(.control),
           shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey)
        {
            return false
        }

        // Match using the current keyboard layout so Command shortcuts stay character-based
        // across layouts (QWERTY, Dvorak, etc.) instead of being tied to ANSI physical keys.
        let layoutCharacter = shortcutLayoutCharacterProvider(event.keyCode, event.modifierFlags)
        if shortcutCharacterMatches(
            eventCharacter: layoutCharacter,
            shortcutKey: shortcutKey,
            applyShiftSymbolNormalization: false,
            eventKeyCode: event.keyCode
        ) {
            return true
        }

        // Control-key combos can surface as ASCII control characters (e.g. Ctrl+H => backspace),
        // so keep ANSI keyCode fallback for control-modified shortcuts. Also allow fallback for
        // command punctuation shortcuts, since some non-US layouts report different characters
        // for the same physical key even when menu-equivalent semantics should still apply.
        let allowANSIKeyCodeFallback = flags.contains(.control)
            || (flags.contains(.command)
                && !flags.contains(.control)
                && (
                    !shouldRequireCharacterMatchForCommandShortcut(shortcutKey: shortcutKey)
                        || (!hasEventChars && (layoutCharacter?.isEmpty ?? true))
                ))
        if allowANSIKeyCodeFallback, let expectedKeyCode = keyCodeForShortcutKey(shortcutKey) {
            return event.keyCode == expectedKeyCode
        }
        return false
    }

    private func shouldRequireCharacterMatchForCommandShortcut(shortcutKey: String) -> Bool {
        guard shortcutKey.count == 1, let scalar = shortcutKey.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    private func shortcutCharacterMatches(
        eventCharacter: String?,
        shortcutKey: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Bool {
        guard let eventCharacter, !eventCharacter.isEmpty else { return false }
        if normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        ) == shortcutKey {
            return true
        }
        return false
    }

    private func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
            case "{": return "["
            case "}": return "]"
            case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
            case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
            case "?": return "/"
            case ":": return ";"
            case "\"": return "'"
            case "|": return "\\"
            case "~": return "`"
            case "+": return "="
            case "_": return "-"
            case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
            case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
            case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
            case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
            case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
            case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
            case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
            case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
            case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
            case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
            default: return lowered
        }
    }

    private func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes. This is intentionally limited to keys we
        // support in StoredShortcut/ghostty trigger translation.
        switch key {
            case "a": 0 // kVK_ANSI_A
            case "s": 1 // kVK_ANSI_S
            case "d": 2 // kVK_ANSI_D
            case "f": 3 // kVK_ANSI_F
            case "h": 4 // kVK_ANSI_H
            case "g": 5 // kVK_ANSI_G
            case "z": 6 // kVK_ANSI_Z
            case "x": 7 // kVK_ANSI_X
            case "c": 8 // kVK_ANSI_C
            case "v": 9 // kVK_ANSI_V
            case "b": 11 // kVK_ANSI_B
            case "q": 12 // kVK_ANSI_Q
            case "w": 13 // kVK_ANSI_W
            case "e": 14 // kVK_ANSI_E
            case "r": 15 // kVK_ANSI_R
            case "y": 16 // kVK_ANSI_Y
            case "t": 17 // kVK_ANSI_T
            case "1": 18 // kVK_ANSI_1
            case "2": 19 // kVK_ANSI_2
            case "3": 20 // kVK_ANSI_3
            case "4": 21 // kVK_ANSI_4
            case "6": 22 // kVK_ANSI_6
            case "5": 23 // kVK_ANSI_5
            case "=": 24 // kVK_ANSI_Equal
            case "9": 25 // kVK_ANSI_9
            case "7": 26 // kVK_ANSI_7
            case "-": 27 // kVK_ANSI_Minus
            case "8": 28 // kVK_ANSI_8
            case "0": 29 // kVK_ANSI_0
            case "]": 30 // kVK_ANSI_RightBracket
            case "o": 31 // kVK_ANSI_O
            case "u": 32 // kVK_ANSI_U
            case "[": 33 // kVK_ANSI_LeftBracket
            case "i": 34 // kVK_ANSI_I
            case "p": 35 // kVK_ANSI_P
            case "l": 37 // kVK_ANSI_L
            case "j": 38 // kVK_ANSI_J
            case "'": 39 // kVK_ANSI_Quote
            case "k": 40 // kVK_ANSI_K
            case ";": 41 // kVK_ANSI_Semicolon
            case "\\": 42 // kVK_ANSI_Backslash
            case ",": 43 // kVK_ANSI_Comma
            case "/": 44 // kVK_ANSI_Slash
            case "n": 45 // kVK_ANSI_N
            case "m": 46 // kVK_ANSI_M
            case ".": 47 // kVK_ANSI_Period
            case "`": 50 // kVK_ANSI_Grave
            case "\r": 36 // kVK_Return
            case "←": 123 // kVK_LeftArrow
            case "→": 124 // kVK_RightArrow
            case "↓": 125 // kVK_DownArrow
            case "↑": 126 // kVK_UpArrow
            default:
                nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    private func matchArrowShortcut(event: NSEvent, shortcut: StoredShortcut, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == shortcut.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == shortcut.modifierFlags
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    private func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if shortcut.key == arrowGlyph {
            return matchArrowShortcut(event: event, shortcut: shortcut, keyCode: arrowKeyCode)
        }
        return matchShortcut(event: event, shortcut: shortcut)
    }

    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            ),
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        let mode = AppIconSettings.resolvedMode()
        if mode == .automatic {
            // Let the asset catalog handle appearance-based icon selection.
            if let icon = NSImage(named: NSImage.applicationIconName) {
                NSApplication.shared.applicationIconImage = icon
            }
        } else {
            AppIconSettings.applyIcon(mode)
        }
    }

    private func scheduleLaunchServicesBundleRegistration(
        bundleURL: URL = Bundle.main.bundleURL.standardizedFileURL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = AppDelegate.enqueueLaunchServicesRegistrationWork,
        register: @escaping (CFURL) -> OSStatus = { url in
            LSRegisterURL(url, true)
        },
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { message, data in
            sentryBreadcrumb(message, category: "startup", data: data)
        }
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        breadcrumb("launchservices.register.schedule", [
            "bundlePath": normalizedURL.path,
        ])

        scheduler {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let registerStatus = register(normalizedURL as CFURL)
            let durationMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())

            breadcrumb("launchservices.register.complete", [
                "bundlePath": normalizedURL.path,
                "status": Int(registerStatus),
                "durationMs": durationMs,
            ])

            if registerStatus != noErr {
                NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(normalizedURL.path)")
            }
        }
    }

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
    }

    private func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let embeddedCLIURL = Bundle.main
            .bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = ProcessInfo.processInfo.processIdentifier

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
            if let executableURL = app.executableURL?
                .standardizedFileURL
                .resolvingSymlinksInPath(),
                executableURL == embeddedCLIURL
            {
                return
            }

            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString)
        else {
            return
        }
        let surfaceId: UUID? = {
            guard let surfaceIdString = response.notification.request.content.userInfo["surfaceId"] as? String else {
                return nil
            }
            return UUID(uuidString: surfaceIdString)
        }()

        switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
                let notificationId: UUID? = {
                    if let id = UUID(uuidString: response.notification.request.identifier) {
                        return id
                    }
                    if let idString = response.notification.request.content.userInfo["notificationId"] as? String,
                       let id = UUID(uuidString: idString)
                    {
                        return id
                    }
                    return nil
                }()
                DispatchQueue.main.async {
                    _ = self.openNotification(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
                }

            case UNNotificationDismissActionIdentifier:
                DispatchQueue.main.async {
                    if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                        self.notificationStore?.markRead(id: notificationId)
                    } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                              let notificationId = UUID(uuidString: notificationIdString)
                    {
                        self.notificationStore?.markRead(id: notificationId)
                    }
                }

            default:
                break
        }
    }

    private func installMainWindowKeyObserver() {
        guard windowKeyObserver == nil else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            setActiveMainWindow(window)
        }
    }

    private func installBrowserAddressBarFocusObservers() {
        guard browserAddressBarFocusObserver == nil, browserAddressBarBlurObserver == nil else { return }

        browserAddressBarFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
            browserAddressBarFocusedPanelId = panelId
            stopBrowserOmnibarSelectionRepeat()
            #if DEBUG
                dlog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
            #endif
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
            if browserAddressBarFocusedPanelId == panelId {
                browserAddressBarFocusedPanelId = nil
                stopBrowserOmnibarSelectionRepeat()
                #if DEBUG
                    dlog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
                #endif
            }
        }
    }

    private func browserPanel(for panelId: UUID) -> BrowserPanel? {
        tabManager?.selectedWorkspace?.browserPanel(for: panelId)
    }

    private func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
        #if DEBUG
            let beforeManagerToken = debugManagerToken(tabManager)
        #endif
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        TerminalController.shared.setActiveTabManager(context.tabManager)
        #if DEBUG
            dlog(
                "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
            )
        #endif
    }

    private func unregisterMainWindow(_ window: NSWindow) {
        // Keep geometry available as a fallback even if the full session snapshot
        // is removed when the last window closes.
        persistWindowGeometry(from: window)
        guard let removed = unregisterMainWindowContext(for: window) else { return }
        commandPaletteVisibilityByWindowId.removeValue(forKey: removed.windowId)
        commandPalettePendingOpenByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteRecentRequestAtByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteEscapeSuppressionByWindowId.remove(removed.windowId)
        commandPaletteEscapeSuppressionStartedAtByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSelectionByWindowId.removeValue(forKey: removed.windowId)
        commandPaletteSnapshotByWindowId.removeValue(forKey: removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = NSApp.keyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false)
                {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            if let nextContext {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            _ = saveSessionSnapshot(
                includeScrollback: false,
                removeWhenEmpty: Self.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
                    isTerminatingApp: isTerminatingApp
                )
            )
        }
    }

    private func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.tabs.contains(where: { $0.id == tabId }) {
                return context
            }
        }
        return nil
    }

    private func openNotificationInContext(_ context: MainWindowContext, tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        guard let window else {
            #if DEBUG
                recordMultiWindowNotificationOpenFailureIfNeeded(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    notificationId: notificationId,
                    reason: "missing_window expectedIdentifier=\(expectedIdentifier)"
                )
            #endif
            return false
        }

        context.sidebarSelectionState.selection = .tabs
        bringToFront(window)
        guard context.tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId) else {
            #if DEBUG
                recordMultiWindowNotificationOpenFailureIfNeeded(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    notificationId: notificationId,
                    reason: "focus_failed"
                )
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                    writeJumpUnreadTestData(["jumpUnreadOpenResult": "0"])
                }
            #endif
            return false
        }

        #if DEBUG
            // UI test support: Jump-to-unread asserts that the correct workspace/panel is focused.
            // Recording via first-responder can be flaky on the VM, so verify focus via the model.
            recordJumpUnreadFocusFromModelIfNeeded(
                tabManager: context.tabManager,
                tabId: tabId,
                expectedSurfaceId: surfaceId
            )
        #endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: context.tabManager,
                notificationStore: store
            )
        }

        #if DEBUG
            recordMultiWindowNotificationFocusIfNeeded(
                windowId: context.windowId,
                tabId: tabId,
                surfaceId: surfaceId,
                sidebarSelection: context.sidebarSelectionState.selection
            )
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadOpenInContext": "1", "jumpUnreadOpenResult": "1"])
            }
        #endif
        return true
    }

    private func openNotificationFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        // If the owning window context hasn't been registered yet, fall back to the "active" window.
        guard let tabManager else {
            #if DEBUG
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                    writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_tabManager"])
                }
            #endif
            return false
        }
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
            #if DEBUG
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                    writeJumpUnreadTestData(["jumpUnreadFallbackFail": "tab_not_in_active_manager"])
                }
            #endif
            return false
        }
        guard let window = (NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })) else {
            #if DEBUG
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                    writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_window"])
                }
            #endif
            return false
        }

        sidebarSelectionState?.selection = .tabs
        bringToFront(window)
        guard tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId) else {
            #if DEBUG
                if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                    writeJumpUnreadTestData([
                        "jumpUnreadFallbackFail": "focus_failed",
                        "jumpUnreadOpenResult": "0",
                    ])
                }
            #endif
            return false
        }

        #if DEBUG
            recordJumpUnreadFocusFromModelIfNeeded(
                tabManager: tabManager,
                tabId: tabId,
                expectedSurfaceId: surfaceId
            )
        #endif

        if let notificationId, let store = notificationStore {
            markReadIfFocused(
                notificationId: notificationId,
                tabId: tabId,
                surfaceId: surfaceId,
                tabManager: tabManager,
                notificationStore: store
            )
        }
        #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadOpenInFallback": "1", "jumpUnreadOpenResult": "1"])
            }
        #endif
        return true
    }

    #if DEBUG
        private func recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: TabManager,
            tabId: UUID,
            expectedSurfaceId: UUID?,
            attempt: Int = 0
        ) {
            let env = ProcessInfo.processInfo.environment
            guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
            guard let expectedSurfaceId else { return }

            // Ensure the expectation is armed even if the view doesn't become first responder.
            armJumpUnreadFocusRecord(tabId: tabId, surfaceId: expectedSurfaceId)

            let maxAttempts = 40
            guard attempt < maxAttempts else { return }

            let isSelected = tabManager.selectedTabId == tabId
            let focused = tabManager.focusedSurfaceId(for: tabId)
            if isSelected, focused == expectedSurfaceId {
                recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.recordJumpUnreadFocusFromModelIfNeeded(
                    tabManager: tabManager,
                    tabId: tabId,
                    expectedSurfaceId: expectedSurfaceId,
                    attempt: attempt + 1
                )
            }
        }
    #endif

    private func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        // Improve reliability across Spaces / when other helper panels are key.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func markReadIfFocused(
        notificationId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard tabManager.selectedTabId == tabId else { return }
            if let surfaceId {
                guard tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
            }
            notificationStore.markRead(id: notificationId)
        }
    }

    #if DEBUG
        private func recordMultiWindowNotificationOpenFailureIfNeeded(
            tabId: UUID,
            surfaceId: UUID?,
            notificationId: UUID?,
            reason: String
        ) {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

            let contextSummaries: [String] = mainWindowContexts.values.map { ctx in
                let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString }.joined(separator: ",")
                let hasWindow = (ctx.window != nil) ? "1" : "0"
                return "windowId=\(ctx.windowId.uuidString) hasWindow=\(hasWindow) tabs=[\(tabIds)]"
            }

            writeMultiWindowNotificationTestData([
                "focusToken": UUID().uuidString,
                "openFailureTabId": tabId.uuidString,
                "openFailureSurfaceId": surfaceId?.uuidString ?? "",
                "openFailureNotificationId": notificationId?.uuidString ?? "",
                "openFailureReason": reason,
                "openFailureContexts": contextSummaries.joined(separator: "; "),
            ], at: path)
        }
    #endif
}

private extension AppDelegate {
    @objc func handleThemesReloadNotification(_: Notification) {
        DispatchQueue.main.async {
            GhosttyApp.shared.reloadConfiguration(source: "distributed.cmux.themes")
        }
    }
}
