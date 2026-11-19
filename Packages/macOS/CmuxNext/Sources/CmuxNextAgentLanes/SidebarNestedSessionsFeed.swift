public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextCompat
public import CmuxNextDaemon
import CmuxNextDesign
public import CmuxNextSidebar
import Foundation
import Observation

/// Feeds the sidebar's nested sessions (`sidebar.nestedSessions`, Claude desktop's Code tab): each workspace's
/// sub-sessions (Claude Code subagents, Codex spawned threads), which acpmux reads from the harness's own store
/// (`_acpmux/chat_subsessions`). A workspace's chats are its agent tabs' sessions on this Mac; each session's chat
/// and turn state come from its lane (`AgentLaneStore.links`). A chat is read again when its session's lane changes
/// state or its chat (a turn starts or ends, a subagent is asked for or reports), never on a timer. Off (`never`),
/// the feed reads nothing and leaves `SidebarNestedSessions.sessions` empty. The session tree's feed owns one
/// (`SidebarSessionTreeFeed.nested`) and starts it.
@MainActor
public final class SidebarNestedSessionsFeed {
    private var task: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    /// One observation per workspace of its agent chats, as the session tree's feed keeps them: a tab change
    /// re-reads that workspace only.
    private var observed: ObservedItems<WorkspaceModel, SidebarSessionTreeFeed.WorkspaceChats>?
    private var listed: [WorkspaceModel] = []
    private let joined = Joined()
    /// Each chat's last read, by chat key, and the lane signature it was read at.
    private var reads: [String: (signature: String, sessions: [SidebarSubSession])] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    @Observable @MainActor final class Joined {
        var chats: [SidebarSessionTreeFeed.WorkspaceChats]?
    }

    /// One workspace's chats on this Mac: each chat key with its session's lane signature (state and chat).
    nonisolated struct Want: Equatable, Sendable {
        var workspace: WorkspaceID
        var chats: [String: String]
    }

    /// One pass: the setting, and each workspace's chats while it is on.
    nonisolated struct Pass: Equatable, Sendable {
        var mode: SidebarNestedSessionsMode
        var wants: [Want]?
    }

    public init() {}

    /// Follows the setting, the lanes and every machine's workspaces from now on. `read` asks acpmux for one chat's
    /// sub-sessions (the app passes its local environment's `chatSubsessions`).
    public func start(workspaces: @escaping @MainActor @Sendable () -> [WorkspaceModel], localHost: String?,
                      read: @escaping @Sendable (String) async throws -> [AcpmuxSubSession],
                      lanes: AgentLaneStore = .shared, nested: SidebarNestedSessions) {
        guard task == nil else { return }
        let joined = joined
        observed = ObservedItems(item: { workspace in SidebarSessionTreeFeed.chats(of: workspace, named: false) }, same: { $0 == $1 },
                                 changed: { [weak self] in self?.settle() })
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        listTask = Task { [weak self] in
            for await trigger in ObservationStream({ () -> ObservationTrigger<[WorkspaceModel]?> in
                ObservationTrigger(DesignSettings.shared.sidebarSections.nestedSessions == .never ? nil : workspaces())
            }) {
                guard let self else { return }
                guard let models = trigger.value else {
                    observed?.cancelAll()
                    listed = []
                    if joined.chats != nil { joined.chats = nil }
                    continue
                }
                listed = models
                settle()
            }
        }
        // task-owner: the app (one feed for the app's life); event-driven (Observation)
        task = Task { [weak self] in
            for await pass in ObservationStream({ () -> Pass in
                let mode = DesignSettings.shared.sidebarSections.nestedSessions
                guard mode != .never, let chats = joined.chats else { return Pass(mode: mode, wants: nil) }
                return Pass(mode: mode, wants: Self.wants(chats, localHost: localHost, links: { lanes.links($0) }))
            }) {
                if nested.mode != pass.mode { nested.mode = pass.mode }
                self?.apply(pass.wants, read: read, nested: nested)
            }
        }
    }

    private func settle() {
        guard let observed else { return }
        let chats = observed.items(for: listed, id: { "\(ObjectIdentifier($0))" })
        if joined.chats != chats { joined.chats = chats }
    }

    /// Each workspace's chats on this Mac with their sessions' lane signatures; workspaces with none are left out.
    static func wants(_ chats: [SidebarSessionTreeFeed.WorkspaceChats], localHost: String?,
                                  links: (String) -> AgentLaneLinks?) -> [Want] {
        chats.compactMap { workspace in
            var keys: [String: String] = [:]
            for ref in workspace.refs where ref.host == localHost {
                guard let session = ref.session, let link = links(session), let chat = link.chat else { continue }
                keys[chat] = "\(link.state)"
            }
            return keys.isEmpty ? nil : Want(workspace: workspace.id, chats: keys)
        }
    }

    /// Reads each chat whose signature moved, and publishes every workspace's sub-sessions.
    private func apply(_ wants: [Want]?, read: @escaping @Sendable (String) async throws -> [AcpmuxSubSession],
                       nested: SidebarNestedSessions) {
        guard let wants else {
            for fetch in inFlight.values { fetch.cancel() }
            (inFlight, reads) = ([:], [:])
            if !nested.sessions.isEmpty { nested.sessions = [:] }
            return
        }
        let live = Set(wants.flatMap(\.chats.keys))
        reads = reads.filter { live.contains($0.key) }
        for want in wants {
            for (chat, signature) in want.chats where reads[chat]?.signature != signature && inFlight[chat] == nil {
                // task-owner: this feed (one read per chat at a time); ends with the read
                inFlight[chat] = Task { [weak self] in
                    let rows = (try? await read(chat)) ?? []
                    guard let self else { return }
                    inFlight[chat] = nil
                    reads[chat] = (signature, rows.map(Self.subSession))
                    publish(wants, nested: nested)
                }
            }
        }
        publish(wants, nested: nested)
    }

    private func publish(_ wants: [Want], nested: SidebarNestedSessions) {
        var sessions: [WorkspaceID: [SidebarSubSession]] = [:]
        for want in wants {
            let subs = want.chats.keys.sorted().flatMap { reads[$0]?.sessions ?? [] }
            if !subs.isEmpty { sessions[want.workspace] = subs }
        }
        if nested.sessions != sessions { nested.sessions = sessions }
    }

    nonisolated static func subSession(_ row: AcpmuxSubSession) -> SidebarSubSession {
        SidebarSubSession(id: row.id, parentID: row.parentID, title: row.title ?? row.kind ?? row.id, kind: row.kind,
                          state: SidebarSubSession.State(rawValue: row.state) ?? .idle)
    }
}
