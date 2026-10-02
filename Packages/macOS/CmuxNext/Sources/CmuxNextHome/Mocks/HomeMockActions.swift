public import Foundation
import CmuxNextWakeups

/// Mock App side: fills a ``HomeViewModel`` from ``HomeMockSource``s and
/// answers its intents. Its responder plays the other side deterministically
/// over one-shot `DemandTimer` deadlines (MessagesLab MODEL.md "Responder"):
/// confirm after 0.3 s, read and typing after 0.8 s, then a reply. A message
/// containing "fail" is rejected, so the failed and retry paths can be shown.
@MainActor
public final class HomeMockActions: HomeActions {
    public let viewModel: HomeViewModel
    public private(set) var sources: [String: HomeMockSource] = [:]
    /// Replies off: sends are confirmed and read only (bench).
    public var replies = true
    private var timers: [Int: DemandTimer] = [:]
    private var nextTimer = 0
    private var replyIndex = 0
    private static let answers = [
        "Got it. Working on it now.",
        "Done. The build is green on the fleet.",
        "I opened a PR with the fix and a regression test.",
        "Two tests failed on main before this change too; not ours.",
        "Starting a sub-agent for that.",
    ]

    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
        viewModel.actions = self
    }

    /// Adds a conversation and its summary row.
    public func add(_ source: HomeMockSource, title: String, ownerLabel: String? = HomeLabels.thisMacOnly) {
        sources[source.conversationID] = source
        let summary = HomeConversationSummary(id: source.conversationID, title: title, participants: source.participants,
                                              lastMessagePreview: "", updatedAt: Date(), ownerLabel: ownerLabel)
        viewModel.conversations.append(summary)
        if viewModel.selectedConversationID == nil { selectConversation(source.conversationID) }
        Task { @MainActor [weak self] in await self?.refreshPreview(source.conversationID) }
    }

    public func send(text: String, replyTo: String?, in conversationID: String) {
        guard let source = sources[conversationID] else { return }
        let clientMsgID = source.addPending([.text(text)], replyTo: replyTo)
        if text.localizedCaseInsensitiveContains("fail") {
            after(0.4) { source.fail(clientMsgID: clientMsgID, reason: "rejected by the mock owner") }
            return
        }
        respond(to: clientMsgID, text: text, in: source)
    }

    public func selectConversation(_ conversationID: String) {
        guard let source = sources[conversationID] else { return }
        viewModel.selectedConversationID = conversationID
        viewModel.transcript = source
    }

    public func createConversation() {
        let me = HomeParticipant(id: "user_local", displayName: "Me", isMe: true)
        let mux = HomeParticipant(id: "agent_mux", displayName: "Mux", isAgent: true)
        let id = "conv_new_\(sources.count + 1)"
        add(HomeMockSource(conversationID: id, participants: [me, mux], history: HomeMemoryHistory([])), title: mux.displayName)
        selectConversation(id)
    }

    public func markRead(seq: Int, in conversationID: String) {
        guard let index = viewModel.conversations.firstIndex(where: { $0.id == conversationID }),
              viewModel.conversations[index].unreadCount != 0 else { return }
        viewModel.conversations[index].unreadCount = 0
    }

    public func retry(clientMsgID: String, in conversationID: String) {
        guard let source = sources[conversationID] else { return }
        source.retry(clientMsgID: clientMsgID)
        respond(to: clientMsgID, text: "", in: source)
    }

    private func respond(to clientMsgID: String, text: String, in source: HomeMockSource) {
        let other = source.participants.first { !$0.isMe }?.id ?? ""
        after(0.3) { [weak self] in
            guard let confirmed = source.confirm(clientMsgID: clientMsgID) else { return }
            self?.touch(source.conversationID, preview: confirmed.parts.first?.plainText)
        }
        after(0.8) { [weak self] in
            if let seq = source.newestSeq { source.setReadThrough(seq) }
            if self?.replies == true { source.setTyping([other]) }
        }
        guard replies else { return }
        let answer = Self.answers[replyIndex % Self.answers.count]
        replyIndex += 1
        let delay = 0.9 + min(3, 0.025 * Double(answer.count))
        after(delay) { [weak self] in
            source.setTyping([])
            source.receive([.text(answer)], from: other)
            self?.touch(source.conversationID, preview: answer)
        }
    }

    private func touch(_ conversationID: String, preview: String?) {
        guard let index = viewModel.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        if let preview { viewModel.conversations[index].lastMessagePreview = preview }
        viewModel.conversations[index].updatedAt = Date()
    }

    private func refreshPreview(_ conversationID: String) async {
        guard let source = sources[conversationID], let newest = source.newestSeq,
              let last = try? await source.page(before: newest + 1, limit: 1).last else { return }
        touch(conversationID, preview: last.parts.first?.plainText ?? "")
        if let index = viewModel.conversations.firstIndex(where: { $0.id == conversationID }) {
            viewModel.conversations[index].updatedAt = last.createdAt
        }
    }

    /// One deadline per scheduled step; released when it fires.
    private func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        nextTimer += 1
        let id = nextTimer
        let timer = DemandTimer(owner: "home.mock.responder")
        timers[id] = timer
        timer.schedule(after: .milliseconds(Int(seconds * 1000))) { @MainActor [weak self] in
            self?.timers[id] = nil
            action()
        }
    }
}
