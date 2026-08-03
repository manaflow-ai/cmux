import AppKit
import Darwin
import Observation

@MainActor
final class TaskManagerWindowController: ReleasingWindowController {
    static let shared = TaskManagerWindowController()

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
        window.contentView = CmuxTaskManagerView(model: model)
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

    @ObservationIgnored private var refreshLoopTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var terminationTasks: [UUID: Task<Void, Never>] = [:]

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
        guard refreshLoopTask == nil else {
            refresh(force: true, showIndicator: false)
            return
        }
        refresh(force: true, showIndicator: !hasLoadedSnapshot)
        refreshLoopTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard let self else { return }
                self.refresh(showIndicator: false)
            }
        }
    }

    func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        for task in terminationTasks.values { task.cancel() }
        terminationTasks.removeAll()
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
              let manager = appDelegate.tabManagerFor(tabId: workspaceId) else { return }
        if let windowId = appDelegate.windowId(for: manager) {
            _ = appDelegate.focusMainWindow(windowId: windowId)
        }
        manager.focusTab(
            workspaceId,
            surfaceId: row.surfaceId,
            suppressFlash: true,
            dismissRestoredUnreadOnResume: true
        )
        flashSelection(workspaceId: workspaceId, surfaceId: row.surfaceId)
    }

    func viewTerminal(for row: CmuxTaskManagerRow) {
        guard let workspaceId = row.workspaceId,
              let terminalSurfaceId = row.terminalSurfaceId,
              let appDelegate = AppDelegate.shared,
              let manager = appDelegate.tabManagerFor(tabId: workspaceId) else { return }
        if let windowId = appDelegate.windowId(for: manager) {
            _ = appDelegate.focusMainWindow(windowId: windowId)
        }
        manager.focusTab(
            workspaceId,
            surfaceId: terminalSurfaceId,
            suppressFlash: true,
            dismissRestoredUnreadOnResume: true
        )
        flashSelection(workspaceId: workspaceId, surfaceId: terminalSurfaceId)
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
        let content: CmuxAlertContent
        if processIds.count == 1, let processId = processIds.first {
            alert.messageText = String(localized: "taskManager.killProcess.title.one", defaultValue: "Kill process?")
            let message = String.localizedStringWithFormat(
                String(
                    localized: "taskManager.killProcess.message.one",
                    defaultValue: "Ask %@ (PID %lld) to terminate gracefully. cmux will force-kill it if it is still running after a short grace period."
                ),
                row.title,
                Int64(processId)
            )
            content = CmuxAlertContent(informativeText: message)
        } else {
            let pidList = processIds.map(String.init).joined(separator: ", ")
            alert.messageText = String(localized: "taskManager.killProcess.title.other", defaultValue: "Kill processes?")
            let message = String.localizedStringWithFormat(
                String(
                    localized: "taskManager.killProcess.message.other",
                    defaultValue: "Ask %lld processes to terminate gracefully. cmux will force-kill remaining processes after a short grace period. PIDs: %@."
                ),
                Int64(processIds.count),
                pidList
            )
            content = CmuxAlertContent.scrollingAll(message)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "taskManager.killProcess.confirm", defaultValue: "Kill"))
        alert.addButton(withTitle: String(localized: "taskManager.killProcess.cancel", defaultValue: "Cancel"))
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }
        return alert.runCmuxModal(content: content) == .alertFirstButtonReturn
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
        terminationTasks[operationId] = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            do {
                try await clock.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self else { return }
            self.terminationTasks.removeValue(forKey: operationId)
            self.forceKillSurvivors(processIds: processIds)
        }
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

    private func flashSelection(workspaceId: UUID, surfaceId: UUID?) {
        guard let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else { return }
        let targetSurfaceId = surfaceId ?? workspace.focusedPanelId
        guard let targetSurfaceId,
              let panel = workspace.panels[targetSurfaceId] else { return }
        panel.triggerFlash(reason: .debug)
    }
}
