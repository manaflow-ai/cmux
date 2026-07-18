import Testing
@testable import CMUXAgentLaunch

@Suite("Codex transcript monitor scanner")
struct CodexTranscriptMonitorScannerTests {
    @Test func findsInputAndTerminalFailureForOnlyTheRequestedTurn() {
        let scanner = CodexTranscriptMonitorScanner()
        let snapshot = scanner.scan(
            lines: [
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"other"}}"#,
                #"{"type":"event_msg","payload":{"type":"request_user_input","turn_id":"other","call_id":"wrong","questions":[{"question":"Wrong turn"}]}}"#,
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"wanted"}}"#,
                #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1","arguments":"{\"questions\":[{\"question\":\"Choose a target\"}]}"}}"#,
                #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"wanted","error":{"message":"stream disconnected","additional_details":"retry exhausted"}}}"#,
            ],
            turnID: "wanted"
        )

        #expect(snapshot.userInput == nil)
        guard case .failure(let failure) = snapshot.state else {
            Issue.record("Expected terminal failure, saw \(snapshot.state)")
            return
        }
        #expect(failure.message == "stream disconnected")
        #expect(failure.additionalDetails == "retry exhausted")
    }

    @Test func publishesPendingInputOnceBeforeCompletion() {
        let scanner = CodexTranscriptMonitorScanner()
        let lines = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"type":"event_msg","payload":{"type":"request_user_input","call_id":"call-1","questions":[{"question":"Pick one"}]}}"#,
        ]
        let first = scanner.scan(lines: lines, turnID: "turn-1")
        #expect(first.userInput?.callID == "call-1")
        #expect(first.userInput?.question == "Pick one")
        #expect(first.state == .pending)

        let duplicate = scanner.scan(
            lines: lines,
            turnID: "turn-1",
            excludingCallIDs: ["call-1"]
        )
        #expect(duplicate.userInput == nil)
        #expect(duplicate.state == .pending)
    }

    @Test func terminalAssistantResponseIsHealthy() {
        let snapshot = CodexTranscriptMonitorScanner().scan(
            lines: [
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done"}]}}"#,
                #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-1"}}"#,
            ],
            turnID: "turn-1"
        )
        #expect(snapshot.state == .healthy)
    }

    @Test func explicitErrorWithoutMessageStillFails() {
        let snapshot = CodexTranscriptMonitorScanner().scan(
            lines: [
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-1","error":{"code":"unexpected"}}}"#,
            ],
            turnID: "turn-1"
        )
        guard case .failure(let failure) = snapshot.state else {
            Issue.record("Expected explicit terminal error to fail, saw \(snapshot.state)")
            return
        }
        #expect(failure.kind == .reported)
    }

    @Test func terminalTurnWithoutFinalResponseFails() {
        let snapshot = CodexTranscriptMonitorScanner().scan(
            lines: [
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-1"}}"#,
            ],
            turnID: "turn-1"
        )
        guard case .failure(let failure) = snapshot.state else {
            Issue.record("Expected missing final response to fail, saw \(snapshot.state)")
            return
        }
        #expect(failure.kind == .missingFinalResponse)
    }

    @Test func streamErrorForTheActiveTurnPublishesBeforeTerminalCompletion() {
        let snapshot = CodexTranscriptMonitorScanner().scan(
            lines: [
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"type":"event_msg","payload":{"type":"stream_error","message":"connection lost"}}"#,
            ],
            turnID: "turn-1"
        )
        guard case .failure(let failure) = snapshot.state else {
            Issue.record("Expected active stream error to fail, saw \(snapshot.state)")
            return
        }
        #expect(failure.message == "connection lost")
        #expect(failure.isStreamError)
    }
}
