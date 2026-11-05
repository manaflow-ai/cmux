import CmuxAgentQuestion
public import CmuxMobileRealtime
import Foundation
import Observation

/// Voice mode on a GUI agent chat: the agent's messages as it finishes
/// them, its permission requests and questions, and a failed turn are read
/// aloud; tool calls, thoughts, plans and edits are not (the user sees them
/// on screen). The user's words are sent as the next prompt.
@MainActor
public final class AgentChatVoiceSource: AgentVoiceSource {
    let store: AgentChatStore
    private let speech: AgentVoiceSpeech

    public init(store: AgentChatStore, speech: AgentVoiceSpeech = AgentVoiceSpeech()) {
        self.store = store
        self.speech = speech
    }

    public var voiceSourceID: String { "chat:\(store.summary.macID):\(store.summary.id)" }
    public var voiceAgentName: String { store.summary.agentName }

    public func startVoiceFeed(_ speak: @escaping @MainActor (String) -> Void) -> AgentVoiceFeed {
        let follower = Follower(store: store, tracker: AgentChatVoiceTracker(speech: speech), speak: speak)
        follower.arm()
        return AgentVoiceFeed { follower.active = false }
    }

    /// Re-armed on every change of the turns (event driven, no polling).
    @MainActor
    private final class Follower {
        let store: AgentChatStore
        var tracker: AgentChatVoiceTracker
        let speak: @MainActor (String) -> Void
        var active = true

        init(store: AgentChatStore, tracker: AgentChatVoiceTracker, speak: @escaping @MainActor (String) -> Void) {
            self.store = store
            self.tracker = tracker
            self.speak = speak
            self.tracker.baseline(store.turns)
        }

        func arm() {
            guard active else { return }
            withObservationTracking {
                _ = store.turns
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.changed() }
            }
        }

        private func changed() {
            guard active else { return }
            for text in tracker.newSpeech(in: store.turns) { speak(text) }
            arm()
        }
    }

    public func sendVoicePrompt(_ text: String) -> String? {
        store.send(prompt: text)
        return nil
    }
}

/// What in a chat is new since voice mode started and worth saying. Pure,
/// so the rules are tested without a store.
struct AgentChatVoiceTracker {
    let speech: AgentVoiceSpeech
    /// Items already said (or there before voice mode started).
    private(set) var said: Set<String> = []
    /// Turns whose end was already handled.
    private(set) var endedTurns: Set<String> = []

    init(speech: AgentVoiceSpeech) {
        self.speech = speech
    }

    /// Everything on screen now counts as heard, except a message still
    /// streaming: it is read once it is complete.
    mutating func baseline(_ turns: [AgentTurn]) {
        for turn in turns {
            for (index, item) in turn.items.enumerated() {
                if turn.status == .running, index == turn.items.count - 1, case .message = item { continue }
                said.insert(item.id)
            }
            if turn.status != .running { endedTurns.insert(turn.id) }
        }
    }

    /// New things to say, in order. A message is said once it is complete:
    /// another item follows it or its turn ended (never a half-streamed one).
    mutating func newSpeech(in turns: [AgentTurn]) -> [String] {
        var out: [String] = []
        for turn in turns {
            let running = turn.status == .running
            for (index, item) in turn.items.enumerated() where !said.contains(item.id) {
                let isLast = index == turn.items.count - 1
                switch item {
                case let .message(_, markdown):
                    guard !running || !isLast else { continue } // still streaming
                    said.insert(item.id)
                    if let text = speech.speakable(markdown) { out.append(text) }
                case let .permission(record):
                    said.insert(item.id)
                    guard record.resolution == nil else { continue }
                    let what = speech.speakable(record.request.toolCall.title) ?? String(localized: "a tool")
                    out.append(String(localized: "Needs your permission: \(what)"))
                case let .question(question):
                    said.insert(item.id)
                    guard case .pending = question.state else { continue }
                    let prompts = question.items.compactMap { speech.speakable($0.prompt) }
                    if !prompts.isEmpty { out.append(prompts.joined(separator: " ")) }
                case .tool, .thought, .plan, .subagents:
                    // Not for the ear: tool calls, diffs, reasoning and plans stay on screen.
                    said.insert(item.id)
                }
            }
            if !running, !endedTurns.contains(turn.id) {
                endedTurns.insert(turn.id)
                switch turn.status {
                case .failed:
                    let reason = turn.errorText.flatMap { speech.speakable($0) }
                    out.append(reason.map { String(localized: "The turn failed: \($0)") } ?? String(localized: "The turn failed."))
                case .completed where turn.lastAnswerMarkdown == nil && turn.hasEdits:
                    // Edits with no words: say that much, never the diff.
                    let files = Set(turn.edits.map { $0.path }).count
                    out.append(files == 1 ? String(localized: "Edited one file.") : String(localized: "Edited \(files) files."))
                default:
                    break
                }
            }
        }
        return out
    }
}
