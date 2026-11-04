#if os(iOS)
import CmuxMobileFeed
import CmuxMobileRealtime
import CmuxMobileTerminal
import Foundation
import Observation

/// Voice mode on a terminal agent (Claude Code, Codex in a terminal): its
/// replies, questions, permission requests and finishes come from the
/// tab's Feed events, the same ones the Feed shows, filtered for the ear;
/// the user's words are typed into the terminal with Return.
@MainActor
final class TerminalVoiceSource: AgentVoiceSource {
    let voiceSourceID: String
    let voiceAgentName: String
    private let workspaceID: String
    private let tabID: String
    private let feed: FeedStore
    private weak var model: TerminalModel?

    init(macID: String, workspaceID: String, tabID: String, agentName: String, feed: FeedStore, model: TerminalModel) {
        voiceSourceID = "terminal:\(macID):\(tabID)"
        voiceAgentName = agentName
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.feed = feed
        self.model = model
    }

    func startVoiceFeed(_ speak: @escaping @MainActor (String) -> Void) -> AgentVoiceFeed {
        let follower = Follower(feed: feed, tracker: TerminalVoiceTracker(workspaceID: workspaceID, tabID: tabID), speak: speak)
        follower.arm()
        return AgentVoiceFeed { follower.active = false }
    }

    func sendVoicePrompt(_ text: String) {
        model?.sendVoicePrompt(text)
    }

    /// Re-armed on every change of the Feed (event driven, no polling).
    @MainActor
    private final class Follower {
        let feed: FeedStore
        var tracker: TerminalVoiceTracker
        let speak: @MainActor (String) -> Void
        var active = true

        init(feed: FeedStore, tracker: TerminalVoiceTracker, speak: @escaping @MainActor (String) -> Void) {
            self.feed = feed
            self.tracker = tracker
            self.speak = speak
            self.tracker.baseline(feed.items)
        }

        func arm() {
            guard active else { return }
            withObservationTracking {
                _ = feed.items
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.changed() }
            }
        }

        private func changed() {
            guard active else { return }
            for text in tracker.newSpeech(in: feed.items) { speak(text) }
            arm()
        }
    }
}

/// Which of a terminal tab's Feed events are new since voice mode started,
/// and what to say for each. Pure, so the rules are tested without a Feed.
struct TerminalVoiceTracker {
    let workspaceID: String
    let tabID: String
    var speech = AgentVoiceSpeech()
    private(set) var seen: Set<String> = []
    /// The last thing said: a finish that repeats the reply before it is not said twice.
    private(set) var lastSaid: String?

    init(workspaceID: String, tabID: String) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }

    /// Everything in the Feed now counts as heard.
    mutating func baseline(_ items: [FeedItem]) {
        seen.formUnion(items.map(\.id))
    }

    mutating func newSpeech(in items: [FeedItem]) -> [String] {
        // The Feed is newest first; speak oldest first.
        let fresh = items.filter { !seen.contains($0.id) && $0.tabID == tabID && $0.workspaceID == workspaceID }
            .sorted { $0.createdAt < $1.createdAt }
        seen.formUnion(items.filter { $0.tabID == tabID && $0.workspaceID == workspaceID }.map(\.id))
        var out: [String] = []
        for item in fresh {
            guard let text = say(item), text != lastSaid else { continue }
            lastSaid = text
            out.append(text)
        }
        return out
    }

    private func say(_ item: FeedItem) -> String? {
        let words = speech.speakable(item.markdown)
        switch item.kind {
        case .response:
            return words
        case let .question(question):
            let prompts = question.items.compactMap { speech.speakable($0.prompt) }
            return prompts.isEmpty ? words : prompts.joined(separator: " ")
        case let .permission(request):
            let what = speech.speakable(request.toolCall.title) ?? words ?? String(localized: "a tool")
            return String(localized: "Needs your permission: \(what)")
        case .finished:
            return words ?? String(localized: "\(item.agentName) finished.")
        case .failed:
            let reason = item.error.flatMap { speech.speakable($0) } ?? words
            return reason.map { String(localized: "\(item.agentName) failed: \($0)") } ?? String(localized: "\(item.agentName) failed.")
        case .needsInput:
            return words ?? String(localized: "\(item.agentName) needs your input.")
        }
    }
}
#endif
