#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import Foundation
import Observation

@MainActor @Observable final class TranscriptDemoModel {
    var input = TranscriptProjectionInput(entries: [])
    var speed = 2
    var isPlaying = false
    var tallFixtureEnabled = false
    var isPlaybackAvailable = true

    private let sessionID = AgentSessionID(rawValue: "demo-session")
    private let directory = SessionDirectoryReplica()
    private let clock = ManualReplicaClock(currentTick: 0)
    private let conversation: ConversationReplica
    private let records: [ReplicaReplayRecord]
    private var index = 0
    private var streamingRevision = 0
    private var syntheticRevision = 0
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
        guard isPlaybackAvailable else { return }
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

    func appendBurstRows() {
        appendSyntheticRows(
            count: 5,
            label: AgentGUIL10n.string("agent.demo.fixture.label.burst", defaultValue: "burst")
        )
    }

    func setTallFixtureEnabled(_ enabled: Bool) {
        tallFixtureEnabled = enabled
        guard enabled else {
            return
        }
        appendSyntheticRows(
            count: 220,
            label: AgentGUIL10n.string("agent.demo.fixture.label.tall", defaultValue: "tall")
        )
    }

    func tearDown() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private func updateInput() {
        input = TranscriptProjectionInput(
            state: conversation.state,
            hasMoreBefore: false,
            streamingTail: streamingTail,
            displayTick: { entry in entry.seq.rawValue * 600 },
            dayKey: { tick in
                tick < 1_800
                    ? AgentGUIL10n.string("agent.demo.day.today", defaultValue: "Today")
                    : AgentGUIL10n.string("agent.demo.day.later", defaultValue: "Later")
            }
        )
    }

    private func appendSyntheticRows(count: Int, label: String) {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        isPlaybackAvailable = false
        let journalID = ensureSyntheticJournal()
        let firstSeq = conversation.tailSeq.rawValue + 1
        let entries = (0..<count).map { offset in
            syntheticEntry(
                journalID: journalID,
                seq: EntrySeq(rawValue: firstSeq + offset),
                label: label,
                ordinal: syntheticRevision + offset + 1
            )
        }
        syntheticRevision += count
        let record = ReplicaReplayRecord(
            tick: max(clock.currentTick + 1, firstSeq * 600),
            origin: .live,
            delta: .entriesAppended(journalID: journalID, entries: entries)
        )
        FixtureReplicaSource(records: [record]).feed(directory: directory, conversations: [sessionID: conversation])
        streamingTail = nil
        updateInput()
    }

    private func ensureSyntheticJournal() -> JournalID {
        if let journalID = conversation.journalID {
            return journalID
        }
        let journalID = JournalID(rawValue: "demo-journal")
        let reset = ReplicaReplayRecord(
            tick: clock.currentTick,
            origin: .resync,
            delta: .journalReset(sessionID: sessionID, newJournal: journalID, tailSeq: EntrySeq(rawValue: 0))
        )
        FixtureReplicaSource(records: [reset]).feed(
            directory: directory,
            conversations: [sessionID: conversation]
        )
        return journalID
    }

    private func syntheticEntry(
        journalID: JournalID,
        seq: EntrySeq,
        label: String,
        ordinal: Int
    ) -> EntrySnapshot {
        let payload: EntryPayload
        if ordinal.isMultiple(of: 5) {
            payload = .toolRun(ToolRunPayload(
                toolName: AgentGUIL10n.string("agent.demo.fixture.toolName", defaultValue: "fixture"),
                argumentSummary: AgentGUIL10n.string("agent.demo.fixture.toolSummary", defaultValue: "append transcript rows"),
                resultSummary: AgentGUIL10n.string("agent.demo.fixture.toolResult", defaultValue: "fixture rows added"),
                isTerminal: false,
                exitCode: 0,
                isRunning: false
            ))
        } else {
            payload = .agentProse(AgentProsePayload(markdown: String(
                format: AgentGUIL10n.string(
                    "agent.demo.fixture.agentFormat",
                    defaultValue: "Synthetic %@ fixture row %d with enough prose to exercise realistic scroll physics."
                ),
                label,
                ordinal
            )))
        }
        return EntrySnapshot(
            journalID: journalID,
            seq: seq,
            kind: payload.kind,
            content: EntryContent(contentHash: 10_000 + ordinal, payload: payload),
            version: EntityVersion(rawValue: UInt64(10_000 + ordinal))
        )
    }
}
#endif
