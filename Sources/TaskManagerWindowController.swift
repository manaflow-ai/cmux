import AppKit
import Darwin
import Observation
import SwiftUI

@MainActor
final class TaskManagerWindowController: ReleasingWindowController {
    /// Composition-root-owned single instance, recorded once at startup.
    /// `nonisolated(unsafe)`: written exactly once in ``AppDelegate/configure``
    /// (with the cmuxApp-owned `@State` controller) before any concurrent reader
    /// exists. Retires together with the transitional ``shared`` accessor once
    /// every call site is injected.
    nonisolated(unsafe) private static var compositionRootInstance: TaskManagerWindowController?

    /// The single instance, lazily constructed on first access. The cmuxApp
    /// `@State` resolves this through ``shared`` and `AppDelegate` installs the
    /// same object as the composition-root instance, so there is exactly one
    /// Task Manager window controller across every consumer.
    private static let instance = TaskManagerWindowController()

    /// Transitional accessor for the de-singletonization (CONVENTIONS §5
    /// `static let shared` → construct-and-inject). The type no longer
    /// self-vivifies an eager `static let shared`; the cmuxApp `@State` owns the
    /// single instance and injects it into `AppDelegate` (which records ownership
    /// via ``installCompositionRootInstance(_:)``). The remaining call sites (the
    /// menu-bar extra and `AppDelegate.openTaskManagerWindow`, plus the View
    /// command palette) still reach the same single object here while they are
    /// migrated to an injected reference; dropping ``shared`` is the end state.
    static var shared: TaskManagerWindowController {
        compositionRootInstance ?? instance
    }

    /// Called once by ``AppDelegate`` (in `configure`, with the cmuxApp-owned
    /// `@State` controller) to record composition-root ownership of the single
    /// instance. Idempotent (keeps the first installed instance).
    static func installCompositionRootInstance(_ instance: TaskManagerWindowController) {
        guard compositionRootInstance == nil else { return }
        compositionRootInstance = instance
    }

    private let model = CmuxTaskManagerModel()

    private override init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.taskManager")
        window.title = String(localized: "taskManager.windowTitle", defaultValue: "Task Manager")
        window.center()
        window.contentView = NSHostingView(rootView: CmuxTaskManagerView(model: model))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    func show() {
        let window = managedWindow()
        if !window.isVisible {
            window.center()
        }
        model.start()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    override func managedWindowWillClose(_ window: NSWindow) {
        model.stop()
    }
}

@MainActor
@Observable
final class CmuxTaskManagerModel {
    private(set) var snapshot = CmuxTaskManagerSnapshot.empty {
        didSet { updateSortedRows() }
    }
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var sortOrder = CmuxTaskManagerSortOrder.defaultOrder {
        didSet { updateSortedRows() }
    }
    var includesProcesses = false {
        didSet {
            guard oldValue != includesProcesses else { return }
            refresh(force: true)
        }
    }

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var terminationTimers: [UUID: Timer] = [:]
    private let refreshInterval: TimeInterval = 3.0
    private let terminationGraceInterval: TimeInterval = 2.0

    private(set) var sortedRows: [CmuxTaskManagerRow] = []
    private(set) var sortedAgentRows: [CmuxTaskManagerRow] = []
    private(set) var sortedAggregateRows: [CmuxTaskManagerRow] = []
    private(set) var sortedChildMemoryRows: [CmuxTaskManagerRow] = []

    init() {
        updateSortedRows()
    }

    var isInitialLoading: Bool {
        !snapshot.hasLoadedResourceUsage && errorMessage == nil
    }

    private var hasLoadedSnapshot: Bool {
        snapshot.hasLoadedResourceUsage
    }

    func sort(by column: CmuxTaskManagerSortOrder.Column) {
        sortOrder = sortOrder.toggled(for: column)
    }

    func start() {
        guard refreshTimer == nil else {
            refresh(force: true, showIndicator: false)
            return
        }
        refresh(force: true, showIndicator: !hasLoadedSnapshot)
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(showIndicator: false)
            }
        }
        timer.tolerance = 0.75
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh(force: Bool = false, showIndicator: Bool? = nil) {
        if refreshTask != nil {
            guard force else { return }
            refreshTask?.cancel()
            refreshTask = nil
            isRefreshing = false
        }

        let includeProcesses = includesProcesses
        let shouldShowIndicator = showIndicator ?? (force || !hasLoadedSnapshot)
        if shouldShowIndicator {
            isRefreshing = true
        }
        refreshTask = Task { @MainActor [weak self] in
            do {
                let payload = try await TerminalController.shared.taskManagerTopPayload(includeProcesses: includeProcesses)
                guard !Task.isCancelled else { return }
                let snapshot = CmuxTaskManagerSnapshot(payload: payload)
                self?.snapshot = snapshot
                self?.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                #if DEBUG
                cmuxDebugLog("taskManager.refresh.error \(String(describing: error))")
                #endif
                self?.errorMessage = String(
                    localized: "taskManager.refresh.error",
                    defaultValue: "Unable to refresh Task Manager data."
                )
            }
            if shouldShowIndicator {
                self?.isRefreshing = false
            }
            self?.refreshTask = nil
        }
    }

    func viewBestTarget(for row: CmuxTaskManagerRow) {
        if row.canViewTerminal {
            viewTerminal(for: row)
        } else if row.canViewWorkspace {
            viewWorkspace(for: row)
        }
    }

    func viewWorkspace(for row: CmuxTaskManagerRow) {
        guard let workspaceId = row.workspaceId,
              let appDelegate = AppDelegate.shared,
              let manager = appDelegate.environment.windowRegistry.tabManagerFor(tabId: workspaceId) else {
            return
        }
        if let windowId = appDelegate.environment.windowRegistry.windowId(for: manager) {
            _ = appDelegate.environment.mainWindowRouter.focusMainWindow(windowId: windowId)
        }
        manager.focusTab(
            workspaceId,
            surfaceId: row.surfaceId,
            suppressFlash: true,
            dismissRestoredUnreadOnResume: true
        )
        flashSelection(workspaceId: workspaceId, surfaceId: row.surfaceId, appDelegate: appDelegate)
    }

    func viewTerminal(for row: CmuxTaskManagerRow) {
        guard let workspaceId = row.workspaceId,
              let terminalSurfaceId = row.terminalSurfaceId,
              let appDelegate = AppDelegate.shared,
              let manager = appDelegate.environment.windowRegistry.tabManagerFor(tabId: workspaceId) else {
            return
        }
        if let windowId = appDelegate.environment.windowRegistry.windowId(for: manager) {
            _ = appDelegate.environment.mainWindowRouter.focusMainWindow(windowId: windowId)
        }
        manager.focusTab(
            workspaceId,
            surfaceId: terminalSurfaceId,
            suppressFlash: true,
            dismissRestoredUnreadOnResume: true
        )
        flashSelection(workspaceId: workspaceId, surfaceId: terminalSurfaceId, appDelegate: appDelegate)
    }

    func killProcess(for row: CmuxTaskManagerRow) {
        let processIds = row.killableProcessIds
        guard !processIds.isEmpty else { return }
        guard confirmKillProcess(row: row, processIds: processIds) else { return }

        var failures: [(target: String, reason: String)] = []
        var sentGracefulSignal = false
        for processGroupId in row.gracefulProcessGroupIds {
            if let reason = sendSignal(SIGTERM, toProcessGroupId: processGroupId) {
                failures.append((processGroupTargetLabel(processGroupId), reason))
            } else {
                sentGracefulSignal = true
            }
        }

        let escalationProcessIds = Array(Set(row.gracefulProcessIds + processIds)).sorted()
        for processId in escalationProcessIds {
            if let reason = sendSignal(SIGTERM, toProcessId: processId) {
                failures.append((processTargetLabel(processId), reason))
            } else {
                sentGracefulSignal = true
            }
        }

        if failures.isEmpty {
            scheduleForceKillIfNeeded(processIds: escalationProcessIds)
        } else {
            let detail = failures
                .map { "\($0.target): \($0.reason)" }
                .joined(separator: ", ")
            errorMessage = String(format: String(
                localized: "taskManager.killProcess.error",
                defaultValue: "Unable to kill process: %@"
            ), detail)
            if sentGracefulSignal {
                scheduleForceKillIfNeeded(processIds: escalationProcessIds)
            } else {
                refresh(force: true)
            }
        }
    }

    private func confirmKillProcess(row: CmuxTaskManagerRow, processIds: [Int]) -> Bool {
        let alert = NSAlert()
        if processIds.count == 1, let processId = processIds.first {
            alert.messageText = String(localized: "taskManager.killProcess.title.one", defaultValue: "Kill process?")
            alert.informativeText = String(format: String(
                localized: "taskManager.killProcess.message.one",
                defaultValue: "Ask %@ (PID %lld) to terminate gracefully. cmux will force-kill it if it is still running after a short grace period."
            ), row.title, Int64(processId))
        } else {
            let pidList = processIds.map(String.init).joined(separator: ", ")
            alert.messageText = String(localized: "taskManager.killProcess.title.other", defaultValue: "Kill processes?")
            alert.informativeText = String(format: String(
                localized: "taskManager.killProcess.message.other",
                defaultValue: "Ask %lld processes to terminate gracefully. cmux will force-kill remaining processes after a short grace period. PIDs: %@."
            ), Int64(processIds.count), pidList)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "taskManager.killProcess.confirm", defaultValue: "Kill"))
        alert.addButton(withTitle: String(localized: "taskManager.killProcess.cancel", defaultValue: "Cancel"))
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func processGroupTargetLabel(_ processGroupId: Int) -> String {
        String(format: String(
            localized: "taskManager.killProcess.target.processGroup",
            defaultValue: "process group %lld"
        ), Int64(processGroupId))
    }

    private func processTargetLabel(_ processId: Int) -> String {
        String(format: String(
            localized: "taskManager.killProcess.target.pid",
            defaultValue: "PID %lld"
        ), Int64(processId))
    }

    private func updateSortedRows() {
        sortedRows = sortOrder.sortedRows(snapshot.rows)
        sortedAgentRows = sortOrder.sortedRows(snapshot.agentRows)
        sortedAggregateRows = sortOrder.sortedRows(snapshot.aggregateRows)
        sortedChildMemoryRows = sortOrder.sortedRows(snapshot.childMemoryRows)
    }

    private func sendSignal(_ signal: Int32, toProcessId processId: Int) -> String? {
        guard processId > 1, processId != Int(getpid()) else { return nil }
        return signalResult(Darwin.kill(pid_t(processId), signal))
    }

    private func sendSignal(_ signal: Int32, toProcessGroupId processGroupId: Int) -> String? {
        guard processGroupId > 1, processGroupId != Int(getpgrp()) else { return nil }
        return signalResult(Darwin.kill(pid_t(-processGroupId), signal))
    }

    private func signalResult(_ result: Int32) -> String? {
        guard result != 0 else { return nil }
        let failureErrno = errno
        guard failureErrno != ESRCH else { return nil }
        return String(cString: strerror(failureErrno))
    }

    private func scheduleForceKillIfNeeded(processIds: [Int]) {
        let operationId = UUID()
        let timer = Timer.scheduledTimer(withTimeInterval: terminationGraceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.terminationTimers.removeValue(forKey: operationId)
                self?.forceKillSurvivors(processIds: processIds)
            }
        }
        timer.tolerance = 0.25
        terminationTimers[operationId] = timer
        refresh(force: true)
    }

    private func forceKillSurvivors(processIds: [Int]) {
        let survivors = processIds.filter(isProcessRunning)
        guard !survivors.isEmpty else {
            refresh(force: true)
            return
        }

        var failures: [(target: String, reason: String)] = []
        for processId in survivors {
            if let reason = sendSignal(SIGKILL, toProcessId: processId) {
                failures.append((processTargetLabel(processId), reason))
            }
        }

        if failures.isEmpty {
            refresh(force: true)
        } else {
            let detail = failures
                .map { "\($0.target): \($0.reason)" }
                .joined(separator: ", ")
            errorMessage = String(format: String(
                localized: "taskManager.killProcess.error",
                defaultValue: "Unable to kill process: %@"
            ), detail)
            refresh(force: true)
        }
    }

    private func isProcessRunning(_ processId: Int) -> Bool {
        guard processId > 1, processId != Int(getpid()) else { return false }
        errno = 0
        let result = Darwin.kill(pid_t(processId), 0)
        if result == 0 {
            return true
        }
        return errno == EPERM
    }

    private func flashSelection(workspaceId: UUID, surfaceId: UUID?, appDelegate: AppDelegate) {
        guard let manager = appDelegate.environment.windowRegistry.tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return }
        let targetSurfaceId = surfaceId ?? workspace.focusedPanelId
        guard let targetSurfaceId,
              let panel = workspace.panels[targetSurfaceId] else { return }
        panel.triggerFlash(reason: .debug)
    }
}
