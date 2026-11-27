import CmuxNextAgentActivity
public import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
public import Observation

/// Allow and Deny on the sidebar's Needs You tray and Priority rows (cmuxterm-hq#7794: a pending
/// tool permission no longer needs the chat opened). Wiring only: each chat of this Mac's acpmux whose
/// lane waits for the person (`.input`) gets one read of its pending prompt through the approval
/// banners' answerer (``AgentApprovalAnswering/pendingApproval(session:)``: one tool permission, else
/// nothing), and a row's Allow or Deny answers that prompt through the same answerer, which re-checks
/// the request and the person's proof before it sends. A question, several prompts or another
/// machine's chat gets no buttons; the row still opens the chat. Reads run off the main thread's turn
/// and only while the session tree or the Priority view is on, for the waiting chats only. One per
/// window's sidebar (``SidebarPriorityFeed/start(_:approvals:)`` owns it).
@Observable @MainActor
public final class SidebarApprovals {
    /// What a waiting chat's prompt was read for: its lane's wait. A lane event that leaves the chat
    /// waiting on the same prompt reads nothing again.
    struct Wait: Hashable, Sendable {
        var since: Date?
        var step: String?
    }

    /// Each waiting chat's one answerable prompt, by acpmux session.
    private(set) var approvals: [String: AgentApproval] = [:]
    let answerer: (any AgentApprovalAnswering)?
    /// The wait each waiting chat's prompt was (or is being) read for.
    @ObservationIgnored private var readFor: [String: Wait] = [:]

    init(answerer: (any AgentApprovalAnswering)?) {
        self.answerer = answerer
    }

    /// Answers through this Mac's acpmux at `environment` (the app's, resolved at launch); nil
    /// (no acpmux, the showcase) answers nothing and shows no buttons.
    public convenience init(environment: AcpmuxEnvironment?) {
        self.init(answerer: environment.map { AcpmuxApprovalAnswerer(environment: $0) as any AgentApprovalAnswering })
    }

    /// The sessions with buttons now, each with the id of the request they answer.
    var answerable: [String: String] { approvals.mapValues(\.permission) }

    /// The chats of this Mac's acpmux (`store`) waiting for the person, while a sidebar surface that
    /// answers is on. Reads the store's waiting sessions (written only when one starts or stops waiting)
    /// and each waiting session's own cell, never the lane map: another agent's step re-reads nothing
    /// (main-thread-scheduling.md section 3, O7).
    static func waitingChats(in store: AgentLaneStore, enabled: Bool) -> [String: Wait] {
        guard enabled else { return [:] }
        var waiting: [String: Wait] = [:]
        for id in store.waitingSessions {
            guard let lane = store.lane(id), lane.state == .input, lane.peer == nil else { continue }
            waiting[id] = Wait(since: lane.since, step: lane.step)
        }
        return waiting
    }

    /// Follows this Mac's waiting chats until the task is cancelled.
    func followLanes(_ store: AgentLaneStore = .shared) -> Task<Void, Never> {
        guard answerer != nil else { return Task {} }
        // task-owner: the window's sidebar bridge (cancelled with the Priority feed); event-driven (Observation)
        return Task { [weak self] in
            for await waiting in ObservationStream({ () -> [String: Wait] in
                let sections = DesignSettings.shared.sidebarSections
                return Self.waitingChats(in: store, enabled: sections.sessionTree || sections.priorityViewEnabled)
            }) {
                self?.sync(waiting)
            }
        }
    }

    /// Reads the prompt of each chat that started waiting (or waits anew), and drops the chats that
    /// no longer wait.
    func sync(_ waiting: [String: Wait]) {
        let gone = approvals.keys.filter { waiting[$0] == nil }
        for session in gone { approvals[session] = nil }
        readFor = readFor.filter { waiting[$0.key] != nil }
        for (session, wait) in waiting where readFor[session] != wait {
            readFor[session] = wait
            if approvals[session] != nil { approvals[session] = nil }
            read(session, for: wait)
        }
    }

    private func read(_ session: String, for wait: Wait) {
        guard let answerer else { return }
        // task-owner: SidebarApprovals.read: one prompt read per wait of a waiting chat.
        Task { [weak self] in
            let approval = await answerer.pendingApproval(session: session)
            guard let self, self.readFor[session] == wait, self.approvals[session] != approval else { return }
            self.approvals[session] = approval
        }
    }

    /// A row's Allow (once) or Deny of `request`, the request its buttons showed. Only while that is
    /// still the chat's prompt here: a press that began on an earlier request answers nothing. The
    /// buttons go at once; answered, the chat's next prompt (if any) is read while it still waits.
    /// Not answered (the prompt ended or changed, no proof), the row keeps no buttons and still opens
    /// the chat.
    func answer(session: String, request: String, allow: Bool) {
        guard approvals[session]?.permission == request, let approval = approvals.removeValue(forKey: session),
              let answerer else { return }
        // task-owner: SidebarApprovals.answer: one answer per press.
        Task { [weak self] in
            let answered = await answerer.answer(approval, allow: allow)
            guard answered, let self, let wait = self.readFor[session] else { return }
            self.read(session, for: wait)
        }
    }

    /// Feeds `view`'s Needs You tray the workspaces that show an answerable chat until the task is
    /// cancelled, and answers its Allow and Deny. `locate` finds those workspaces
    /// (``SidebarSessionTreeFeed/workspaces(showing:)``).
    func followTray(_ view: SidebarView,
                    locate: @escaping @MainActor (Set<String>) -> [SidebarWorkspaceID: String]) -> Task<Void, Never> {
        view.onAnswer = { [weak self] workspace, request, allow in
            guard let self, let session = locate(Set(self.answerable.keys))[workspace] else { return }
            self.answer(session: session, request: request, allow: allow)
        }
        // task-owner: the window's sidebar bridge (cancelled with the Priority feed); event-driven (Observation)
        return Task { [weak self, weak view] in
            for await shown in ObservationStream({ () -> [SidebarWorkspaceID: String] in
                let answerable = self?.answerable ?? [:]
                return locate(Set(answerable.keys)).compactMapValues { answerable[$0] }
            }) {
                view?.showAnswerable(shown)
            }
        }
    }
}
