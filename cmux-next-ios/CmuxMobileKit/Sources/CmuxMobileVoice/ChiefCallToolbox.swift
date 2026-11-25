import CmuxConversationCore
public import CmuxMobileChief
import CmuxMobileModel
public import CmuxMobileRealtime
import Foundation

/// Chief's tools on a live call, over what the app already holds: the
/// called Chief's conversation, the workspaces and the Feed (``AppStore``).
/// Nothing here reaches past what the user can see and do in the app; the
/// one action, send_to_chief, is the composer's send.
///
/// Scoped to the Chief the user called, and only it (Aziz 2026-11-05: a call
/// to one Chief read and wrote the Cloud Chief, ``ChiefSources/primary``).
/// The Cloud session is shared by every Cloud Chief of the account (Home
/// switches it to the one opened), so the call also pins the called Chief's
/// id: once the session shows another Chief, the call reads and sends nothing.
@MainActor
public final class ChiefCallToolbox: VoiceCallToolbox {
    private let chief: ChiefSession
    /// The called Chief's id (``ChiefIdentity/chiefID``), fixed for the call.
    public let chiefID: String
    /// The Mac a Mac Chief runs on, once known: every Mac's Chief has the same id, and the
    /// Mac Chief's session follows the Mac the phone shows.
    private var macID: String?
    public let chiefName: String
    private let store: AppStore
    private let userName: String?

    public init(chief: ChiefSession, store: AppStore, userName: String?) {
        self.chief = chief
        chiefID = chief.identity.chiefID
        macID = chief.runsInCloud ? nil : chief.macID
        let name = chief.title ?? chief.identity.title
        chiefName = name.isEmpty ? "Chief" : name
        self.store = store
        self.userName = userName
    }

    /// The called Chief is still the one its session holds: the same Chief, and for a
    /// Mac Chief the same Mac (the first Mac it shows, when the call began before one).
    public var isScoped: Bool {
        guard chief.identity.chiefID == chiefID else { return false }
        guard !chief.runsInCloud, let now = chief.macID else { return true }
        guard let macID else {
            macID = now
            return true
        }
        return now == macID
    }

    /// What the call's tools say once the session shows another Chief.
    private var outOfScope: VoiceCallToolResult {
        VoiceCallToolResult(object: [
            "error": "chief_closed",
            "note": "This call is to \(chiefName), which is no longer open on this phone. Nothing was read or sent; tell the user to call \(chiefName) again.",
        ])
    }

    public func briefing() -> VoiceCallBriefing {
        VoiceCallBriefing(chiefName: chiefName, userName: userName, chiefStatus: status,
                          recentMessages: recentLines(count: 8, limit: 400),
                          workspaces: workspaceLines.prefix(15).map(\.self),
                          attention: attentionLines.prefix(10).map(\.self))
    }

    /// Where Chief runs and whether a message reaches it now.
    private var status: String {
        if chief.runsInCloud {
            return chief.isConnected ? "Runs in cmux Cloud and is connected." : "Runs in cmux Cloud; not connected right now, messages wait and send when it is."
        }
        guard chief.isConnected else {
            let reason = chief.unavailableReason ?? "not connected"
            return "Runs on the user's Mac; \(reason). Messages wait in the outbox and send when Chief connects."
        }
        let mac = chief.macName.map { "on \($0)" } ?? "on the user's Mac"
        return "Runs \(mac) and is connected\(chief.isWorking ? "; it is working on something now" : "")."
    }

    public func sendToChief(_ message: String) async -> VoiceCallToolResult {
        guard isScoped else { return outOfScope }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return VoiceCallToolResult(object: ["error": "empty message"]) }
        let connected = chief.acceptsSendsNow && chief.isConnected
        chief.send(ConversationComposeMessage(text: text), asksForAlerts: false)
        return VoiceCallToolResult(
            object: ["status": connected ? "sent" : "queued",
                     "note": connected ? "Chief got the message; its reply will arrive as a system message."
                         : "Chief isn't connected; the message waits and sends when it connects."],
            activity: connected ? String(localized: "Sent to Chief: “\(text)”") : String(localized: "Queued for Chief: “\(text)”"))
    }

    public func readChiefMessages(count: Int) -> VoiceCallToolResult {
        guard isScoped else { return outOfScope }
        return VoiceCallToolResult(object: ["messages": recentLines(count: count, limit: 1200)],
                            activity: String(localized: "Read the Chief chat"))
    }

    public func listWorkspaces() -> VoiceCallToolResult {
        let lines = workspaceLines
        return VoiceCallToolResult(object: ["workspaces": Array(lines.prefix(40)), "total": lines.count],
                                   activity: String(localized: "Checked workspaces"))
    }

    public func listNeedsAttention() -> VoiceCallToolResult {
        let lines = attentionLines
        return VoiceCallToolResult(object: ["items": Array(lines.prefix(20)), "total": lines.count],
                                   activity: String(localized: "Checked what needs you"))
    }

    // MARK: Lines

    /// The newest text messages, oldest first, each cut to `limit` characters.
    private func recentLines(count: Int, limit: Int) -> [String] {
        guard isScoped else { return [] }
        let store = chief.store
        let messages = store.messages.filter { !$0.text.isEmpty && $0.unsentAt == nil && $0.systemEvent == nil }
        return messages.suffix(count).map { message in
            let who = message.senderID == store.meID ? "User" : chiefName
            let text = message.text.count > limit ? message.text.prefix(limit) + "…" : Substring(message.text)
            return "\(who): \(text)"
        }
    }

    private var macNames: [String: String] {
        Dictionary(store.teams.flatMap(\.macs).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Most recently active first: name, Mac, folder, branch, agents.
    private var workspaceLines: [String] {
        let macs = macNames
        return store.workspaces.sorted { $0.lastActivityAt > $1.lastActivityAt }.map { workspace in
            var parts = ["\(workspace.title)"]
            if let mac = macs[workspace.macID] { parts.append("on \(mac)") }
            if !workspace.directory.isEmpty { parts.append("folder \(workspace.directory)") }
            if let branch = workspace.branch, !branch.isEmpty { parts.append("branch \(branch)") }
            let agents = workspace.tabs.filter { $0.agentStatus != nil }.map { tab -> String in
                let who = tab.harness.map { "\(tab.title) (\($0))" } ?? tab.title
                switch (tab.agentStatus, tab.waitingFor) {
                case (.waiting, .permission?): return "\(who) waiting for permission"
                case (.waiting, .question?): return "\(who) asking a question"
                case (.waiting, nil): return "\(who) waiting"
                default: return "\(who) working"
                }
            }
            if !agents.isEmpty { parts.append("agents: " + agents.joined(separator: ", ")) }
            else if workspace.isWorking { parts.append("working") }
            if workspace.needsAttention { parts.append("needs attention") }
            return parts.joined(separator: "; ")
        }
    }

    /// Open questions and permission requests first, then recent finishes.
    private var attentionLines: [String] {
        let titles = Dictionary(store.workspaces.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let open = store.feed.filter { !$0.isResolved }.sorted { $0.createdAt > $1.createdAt }
        return open.compactMap { event in
            let place = titles[event.workspaceID].map { " in \($0)" } ?? ""
            let what = event.markdown.count > 240 ? event.markdown.prefix(240) + "…" : Substring(event.markdown)
            switch event.kind {
            case let .question(prompt):
                let question = prompt.items.first?.question ?? String(what)
                return "\(event.agentName)\(place) asks: \(question)"
            case let .permission(options):
                return "\(event.agentName)\(place) needs permission: \(what) (options: \(options.joined(separator: ", ")))"
            case let .completion(succeeded):
                return "\(event.agentName)\(place) \(succeeded ? "finished" : "failed"): \(what)"
            case .agentResponse:
                return nil
            }
        }
    }
}
