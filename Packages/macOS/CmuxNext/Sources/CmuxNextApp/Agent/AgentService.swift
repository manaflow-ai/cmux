import AppKit
import CmuxAcpmux
import CmuxConversation
import CmuxNextAcpmux
import CmuxNextControl
import CmuxNextConversationUI
import Foundation
import IOKit.pwr_mgt
import os

/// The agent GUI's app-side owner: runs the app's acpmux daemon, connects
/// the conversation backend to it, opens the agent window, and keeps the Mac
/// from idle sleep while an agent turn runs.
@MainActor
final class AgentService {
    private(set) var supervisor: AcpmuxSupervisor?
    private(set) var backend: AcpmuxBackend?
    private(set) var window: AgentWindowController?
    private(set) var supervisorState: AcpmuxSupervisorState = .stopped
    private(set) var configuration: AcpmuxLaunchConfiguration?
    /// Hold a power assertion while any conversation's turn runs.
    var keepAwakeDuringTurns = true {
        didSet { applyKeepAwake() }
    }
    private(set) var busyConversations = 0
    private var assertion: IOPMAssertionID = 0
    private var stateTask: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    private var outbox: FileOutboxStore?
    private var dataDirectory: URL?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent")

    /// Starts the daemon and the backend. Without a bundled acpmux the agent
    /// GUI stays unavailable.
    func start(launch: LaunchIdentity) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let configuration = AcpmuxLaunchConfiguration.forApp(tag: launch.tag, bundle: .main, processEnvironment: ProcessInfo.processInfo.environment, applicationSupport: support) else {
            supervisorState = .unavailable
            logger.info("agent GUI unavailable: no acpmux binary bundled")
            return
        }
        self.configuration = configuration
        let data = configuration.home.deletingLastPathComponent().appendingPathComponent("agent", isDirectory: true)
        dataDirectory = data
        outbox = FileOutboxStore(directory: data.appendingPathComponent("outbox", isDirectory: true))
        let supervisor = AcpmuxSupervisor(configuration: configuration)
        self.supervisor = supervisor
        let backend = AcpmuxBackend(opener: UnixSocketStreamOpener { await supervisor.readySocketPath() }, clientName: "cmux-mac", singleAttachment: false)
        self.backend = backend
        // task-owner: the app's lifetime; stop() cancels it
        stateTask = Task { [weak self] in
            for await state in await supervisor.states() {
                self?.supervisorState = state
            }
        }
        let list = backend.conversationList()
        // task-owner: the app's lifetime; stop() cancels it
        listTask = Task { [weak self] in
            for await summaries in list {
                self?.busyConversations = summaries.filter { $0.status.isBusy }.count
                self?.applyKeepAwake()
            }
        }
        // task-owner: one hop onto the supervisor actor; start() returns at once
        Task { await supervisor.start() }
    }

    /// The daemon's socket while it runs, for the phone's relay lanes.
    func socketPath() async -> String? {
        await supervisor?.readySocketPath()
    }

    /// Opens (or brings forward) the agent window.
    @discardableResult
    func showWindow() -> AgentWindowController? {
        if window == nil, let backend, let outbox, let data = dataDirectory {
            let workspace = data.appendingPathComponent("workspace", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            window = AgentWindowController(backend: backend, outbox: outbox, previewDirectory: data.appendingPathComponent("previews", isDirectory: true), defaultDirectory: workspace.path)
        }
        window?.showWindow(nil)
        return window
    }

    private func applyKeepAwake() {
        let want = keepAwakeDuringTurns && busyConversations > 0
        if want, assertion == 0 {
            var id: IOPMAssertionID = 0
            let reason = "An agent turn is running" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Whether the keep-awake assertion is held right now.
    var isHoldingKeepAwake: Bool { assertion != 0 }

    /// Stops the daemon (the app is quitting).
    func stop() async {
        stateTask?.cancel()
        listTask?.cancel()
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        await backend?.shutdown()
        await supervisor?.stop()
    }
}
