import CmuxLinkTesting
import CmuxMobileHost
import CmuxMobileWire
import CmuxTerminalStream
import Foundation

/// An in-memory daemon: a mutable tree, change signals, recorded ops and
/// scripted terminal attaches.
actor FakeDaemon: MobileDaemon {
    private(set) var state: MobileWorkspaceState
    private(set) var ops: [MobileDaemonOp] = []
    private var changeSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    let attachments = AsyncQueue<FakeAttachment>()
    var attachError: MobileDaemonError?
    /// Changes the tree right after the first read answers (a delta racing the initial load).
    var raceFirstRead: ((inout MobileWorkspaceState) -> Void)?

    init(state: MobileWorkspaceState = FakeDaemon.sample) {
        self.state = state
    }

    static let sample = MobileWorkspaceState(host: "h_mac1", workspaces: [
        MobileWorkspace(id: "ws_a1", name: "main", order: 0, panes: [
            MobilePane(id: "pane_p1", tabs: [
                MobileTab(id: "tab_t1", kind: .terminal, title: "zsh", terminal: "term_x1", status: .idle, unread: 0),
            ]),
        ]),
    ])

    func workspaceState() async throws -> MobileWorkspaceState {
        let answer = state
        if let race = raceFirstRead {
            raceFirstRead = nil
            mutate(race)
        }
        return answer
    }

    func setRaceFirstRead(_ race: @escaping @Sendable (inout MobileWorkspaceState) -> Void) { raceFirstRead = race }

    func workspaceChanges() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changeSubscribers[UUID()] = continuation
        return stream
    }

    /// Replaces the tree and signals subscribers, like a daemon tree delta.
    func mutate(_ change: (inout MobileWorkspaceState) -> Void) {
        change(&state)
        for continuation in changeSubscribers.values { continuation.yield() }
    }

    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult {
        ops.append(op)
        switch op {
        case .renameWorkspace(let id, let name):
            guard let index = state.workspaces.firstIndex(where: { $0.id == id }) else {
                throw MobileDaemonError(code: "workspace.not_found", message: id)
            }
            state.workspaces[index].name = name
        case .closeTab(let tab):
            for w in state.workspaces.indices {
                for p in state.workspaces[w].panes.indices {
                    state.workspaces[w].panes[p].tabs.removeAll { $0.id == tab }
                }
            }
        case .closeWorkspace(let id):
            guard state.workspaces.contains(where: { $0.id == id }) else {
                throw MobileDaemonError(code: "workspace.not_found", message: id)
            }
            state.workspaces.removeAll { $0.id == id }
        case .markWorkspaceRead(let id):
            guard let w = state.workspaces.firstIndex(where: { $0.id == id }) else {
                throw MobileDaemonError(code: "workspace.not_found", message: id)
            }
            for p in state.workspaces[w].panes.indices {
                for t in state.workspaces[w].panes[p].tabs.indices { state.workspaces[w].panes[p].tabs[t].unread = 0 }
            }
        case .moveWorkspace(let id, let placement, let index):
            guard let moving = state.workspaces.first(where: { $0.id == id }) else {
                throw MobileDaemonError(code: "workspace.not_found", message: id)
            }
            var ordered = state.workspaces.sorted { $0.order < $1.order }.filter { $0.id != id }
            var moved = moving
            switch placement {
            case .keep: break
            case .ungrouped: moved.group = nil
            case .group(let group): moved.group = state.group(group)
            }
            let members = ordered.enumerated().filter { $0.element.group?.id == moved.group?.id }.map(\.offset)
            let position: Int
            if members.isEmpty {
                position = min(state.workspaces.sorted { $0.order < $1.order }.firstIndex { $0.id == id } ?? ordered.count, ordered.count)
            } else if index < members.count {
                position = members[index]
            } else {
                position = members[members.count - 1] + 1
            }
            ordered.insert(moved, at: position)
            for i in ordered.indices { ordered[i].order = i }
            state.workspaces = ordered
        case .renameGroup(let group, let name):
            guard state.group(group) != nil else { throw MobileDaemonError(code: "workspace.group_not_found", message: group) }
            for w in state.workspaces.indices where state.workspaces[w].group?.id == group { state.workspaces[w].group?.name = name }
            if let g = state.groups?.firstIndex(where: { $0.id == group }) { state.groups?[g].name = name }
        case .customizeWorkspace(let id, let color, let icon):
            guard let w = state.workspaces.firstIndex(where: { $0.id == id }) else {
                throw MobileDaemonError(code: "workspace.not_found", message: id)
            }
            switch color {
            case .unchanged: break
            case .clear: state.workspaces[w].color = nil
            case .set(let value): state.workspaces[w].color = value
            }
            switch icon {
            case .unchanged: break
            case .clear: state.workspaces[w].icon = nil
            case .set(let value): state.workspaces[w].icon = value
            }
        case .createWorkspace, .createTab:
            break
        }
        return MobileDaemonOpResult()
    }

    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        if let attachError { throw attachError }
        let attachment = FakeAttachment(request: request)
        await attachments.push(attachment)
        return attachment
    }

    func failAttach(_ error: MobileDaemonError?) { attachError = error }
}

/// A scripted attach that records everything the bridge forwards.
actor FakeAttachment: MobileTerminalAttachment {
    nonisolated let request: MobileTerminalAttachRequest
    nonisolated let opened = TerminalOpenedParams(generation: 7, cols: 80, rows: 24, snapshotVersion: 1, title: "zsh")
    nonisolated let events: AsyncStream<MobileTerminalEvent>
    private nonisolated let continuation: AsyncStream<MobileTerminalEvent>.Continuation
    private(set) var inputs: [TerminalInput] = []
    private(set) var viewports: [TerminalViewport] = []
    private(set) var presence: [(Bool, Bool)] = []
    private(set) var snapshotRequests: [MobileSnapshotRequest] = []
    private(set) var detached = false
    let recorded = AsyncQueue<String>()

    init(request: MobileTerminalAttachRequest) {
        self.request = request
        (events, continuation) = AsyncStream<MobileTerminalEvent>.makeStream()
    }

    nonisolated func emit(_ event: MobileTerminalEvent) { continuation.yield(event) }

    func write(_ input: TerminalInput) async {
        inputs.append(input)
        await recorded.push("input")
    }

    func setViewport(_ viewport: TerminalViewport) async {
        viewports.append(viewport)
        await recorded.push("viewport")
    }

    func setPresence(visible: Bool, counts: Bool) async {
        presence.append((visible, counts))
        await recorded.push("presence")
    }

    func requestSnapshot(_ request: MobileSnapshotRequest) async {
        snapshotRequests.append(request)
        await recorded.push("snapshot:\(request.reason)")
    }

    func detach() async {
        detached = true
        continuation.finish()
        await recorded.push("detach")
    }
}
