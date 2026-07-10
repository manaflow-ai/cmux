#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Observation

@MainActor @Observable final class TranscriptDemoModel {
    var input = TranscriptProjectionInput(entries: [])
    var speed = 2
    var isPlaying = false
    var focusToken = 0

    private let sessionID = AgentSessionID(rawValue: "demo-session")
    private let directory = SessionDirectoryReplica()
    private let clock = ManualReplicaClock(currentTick: 0)
    private let conversation: ConversationReplica
    private let records: [ReplicaReplayRecord]
    private var index = 0
    private var streamingRevision = 0
    private var streamingTail: TranscriptStreamingTail?
    private var playbackTask: Task<Void, Never>?

    init() {
        conversation = ConversationReplica(sessionID: sessionID, clock: clock)
        if let url = Bundle.module.url(forResource: "demo-transcript", withExtension: "jsonl"),
           let data = try? Data(contentsOf: url) {
            records = ReplicaReplayLog.decodeJSONL(data).records
        } else {
            records = []
        }
        updateInput()
    }

    func step() {
        guard index < records.count else {
            isPlaying = false
            playbackTask?.cancel()
            playbackTask = nil
            return
        }
        let record = records[index]
        clock.currentTick = record.tick
        FixtureReplicaSource(records: [record]).feed(directory: directory, conversations: [sessionID: conversation])
        index += 1
        streamingTail = nil
        updateInput()
    }

    func togglePlayback() {
        if isPlaying {
            playbackTask?.cancel()
            playbackTask = nil
            isPlaying = false
            return
        }
        isPlaying = true
        playbackTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                self.step()
                guard self.isPlaying else {
                    return
                }
                let delayMs = self.speed == 10 ? 100 : 500
                // Demo pacing helper; production transcript UI is event-driven.
                try? await Task.sleep(for: .milliseconds(delayMs))
            }
        }
    }

    func injectStreamingTick() {
        streamingRevision += 1
        let tail = max(conversation.tailSeq.rawValue, 0)
        streamingTail = TranscriptStreamingTail(
            journalID: conversation.journalID ?? JournalID(rawValue: "demo-journal"),
            afterSeq: EntrySeq(rawValue: tail),
            textTail: AgentGUIL10n.string("agent.demo.streamingText", defaultValue: "Drafting the next update..."),
            revision: streamingRevision
        )
        updateInput()
    }

    func toggleKeyboard() {
        focusToken += 1
    }

    func tearDown() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private func updateInput() {
        input = TranscriptProjectionInput(
            state: conversation.state,
            hasMoreBefore: true,
            streamingTail: streamingTail,
            displayTick: { entry in entry.seq.rawValue * 600 },
            dayKey: { tick in
                tick < 1_800
                    ? AgentGUIL10n.string("agent.demo.day.today", defaultValue: "Today")
                    : AgentGUIL10n.string("agent.demo.day.later", defaultValue: "Later")
            }
        )
    }
}
#endif
