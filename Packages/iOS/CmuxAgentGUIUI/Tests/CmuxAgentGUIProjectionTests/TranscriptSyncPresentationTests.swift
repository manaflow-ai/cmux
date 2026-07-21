import CmuxAgentGUIProjection
import CmuxAgentReplica
import CmuxAgentSync
@testable import CmuxAgentGUIUI
import Foundation
import Testing

@Suite
struct TranscriptSyncPresentationTests {
    @Test(arguments: [
        (AgentConnectivityPhase.updating, 0, false, TranscriptSyncPresentation.loading),
        (.connecting(backoffMilliseconds: 500), 1, false, .loading),
        (.connecting(backoffMilliseconds: 500), 2, false, .error),
        (.connecting(backoffMilliseconds: 500), 2, true, .stale),
    ])
    func connectivityPresentation(
        phase: AgentConnectivityPhase,
        failures: Int,
        hasContent: Bool,
        expected: TranscriptSyncPresentation
    ) {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: false,
            entries: [],
            sendTickets: hasContent ? [Self.ticket] : []
        )

        #expect(Self.presentation(phase: phase, failures: failures, input: input) == expected)
    }

    @Test
    func openExistingConversationDoesNotFlashEmptyBeforeInitialPull() {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: false,
            entries: []
        )

        #expect(Self.presentation(input: input) == .hidden)
        #expect(!Self.presentation(input: input).showsPlaceholderRow)
    }

    @Test
    func pendingFirstSendSuppressesEmptyPlaceholder() {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: true,
            entries: [],
            sendTickets: [Self.ticket]
        )

        #expect(input.hasVisibleContent)
        #expect(Self.presentation(input: input) == .hidden)
    }

    @Test
    func activeAskOnlySuppressesEmptyPlaceholder() {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: true,
            entries: [],
            asks: [PendingAsk(
                id: "ask-1",
                sessionID: Self.sessionID,
                kind: .question,
                promptSummary: "Choose",
                options: ["A", "B"],
                state: .active
            )]
        )

        #expect(input.hasVisibleContent)
        #expect(Self.presentation(input: input) == .hidden)
    }

    @Test
    func streamingTailOnlySuppressesEmptyPlaceholder() {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: true,
            entries: [],
            streamingTail: TranscriptStreamingTail(
                journalID: Self.journalID,
                afterSeq: EntrySeq(rawValue: 0),
                textTail: "Working answer",
                revision: 1
            )
        )

        #expect(input.hasVisibleContent)
        #expect(Self.presentation(input: input) == .hidden)
    }

    @Test
    func genuinelyEmptyConversationShowsPlaceholderAfterInitialSync() {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: true,
            entries: []
        )

        #expect(!input.hasVisibleContent)
        #expect(Self.presentation(input: input) == .empty)
    }

    @Test
    func emptyFilteredPageShowsLoadingWhileNewerHistoryExists() {
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: true,
            entries: [],
            hasMoreAfter: true,
            endCursor: JournalCursor(rawValue: "next-page")
        )

        #expect(!input.hasVisibleContent)
        #expect(Self.presentation(input: input) == .loading)
        #expect(Self.presentation(input: input).showsPlaceholderRow)
    }

    @Test
    func internalOnlyPageKeepsLoadingInsteadOfShowingAnEmptyConversation() {
        let internalEntry = EntrySnapshot(
            journalID: Self.journalID,
            seq: EntrySeq(rawValue: 10),
            kind: .status,
            content: EntryContent(
                contentHash: 10,
                payload: .status(StatusPayload(code: .sessionMeta))
            ),
            version: EntityVersion(rawValue: 1)
        )
        let input = TranscriptProjectionInput(
            hasCompletedInitialSync: true,
            entries: [internalEntry],
            hasMoreAfter: true,
            endCursor: JournalCursor(rawValue: "next-page")
        )

        #expect(!input.hasVisibleContent)
        #expect(Self.presentation(input: input) == .loading)
        #expect(Self.presentation(input: input).showsPlaceholderRow)
    }

    private static let sessionID = AgentSessionID(rawValue: "presentation-session")
    private static let journalID = JournalID(rawValue: "presentation-journal")
    private static let ticket = SendTicket(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sessionID: sessionID,
        text: "Hello",
        attachmentCount: 0,
        state: .queuedLocal,
        createdAt: 1
    )

    private static func presentation(
        phase: AgentConnectivityPhase = .connected,
        failures: Int = 0,
        input: TranscriptProjectionInput
    ) -> TranscriptSyncPresentation {
        TranscriptSyncPresentation(
            phase: phase,
            consecutiveFailures: failures,
            input: input
        )
    }
}
