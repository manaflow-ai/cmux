import CmuxMobileAgentChat
import CmuxMobileFeed
import Foundation
import Testing
@testable import CmuxMobileLive

/// The `cmux` harness refused by the cmux model service (403): the chat and the Feed say so in
/// plain words, and a model retry shows on the running turn instead of a bare "Working".
@MainActor
@Suite struct TurnFailureLiveTests {
    func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func apiRetryRecordBecomesARetry() {
        let records = AcpmuxRecords(sessionID: "s1")
        let line = json(#"{"seq":9,"at":1700000000000,"dir":"in","kind":"claude.system.api_retry","msg":{"type":"system","subtype":"api_retry","attempt":3,"max_retries":10,"retry_delay_ms":2000,"error_status":503,"error":"server_error"}}"#)
        #expect(records.map(line) == [.retrying(attempt: 3, maxAttempts: 10, status: 503)])
        // Other raw lines still draw nothing.
        let other = json(#"{"seq":10,"dir":"in","kind":"claude.system.status","msg":{"type":"system","subtype":"status"}}"#)
        #expect(records.map(other).isEmpty)
    }

    @Test func failedTurnFeedItemSaysWhy() throws {
        let forbidden = #"API Error: 403 {\"error\":{\"code\":\"auth.forbidden\",\"message\":\"this team cannot use the model router on this deployment yet\"}}"#
        let session = try #require(AcpmuxSession(json(#"{"sessionId":"s1","name":"","harness":"cmux","cwd":"/tmp/w","status":"ready","pendingPermissions":0,"lastSeq":12,"preview":"An earlier reply","lastTurn":{"status":"failed","turnId":"t2","errorText":"\#(forbidden)"}}"#)))
        #expect(session.lastTurnError?.hasPrefix("API Error: 403") == true)
        let feed = LiveFeed(store: FeedStore(items: []), hub: AcpmuxHub(), place: { _ in nil })
        let item = feed.turnItem(session, fallbackKey: "t2", at: Date())
        #expect(item.kind == .failed)
        #expect(item.markdown == "cmux's model service isn't available for this team yet.")
    }
}

/// acpmux's `user_message` names the images a prompt sent (`images: [{id, mimeType, name?}]`).
@Suite struct RecordedPromptImagesTests {
    @Test func userMessageImagesBecomeRecordedAttachments() {
        let records = AcpmuxRecords(sessionID: "s1")
        let line = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"seq":3,"at":1700000000000,"dir":"mux","kind":"user_message","msg":{"text":"look","promptId":"p1","turnId":"t1","images":[{"id":"abc","mimeType":"image/png"},{"id":"def","mimeType":"image/jpeg","name":"cat.jpg"},{"mimeType":"image/png"}]}}"#.utf8))
        guard case .userMessage(_, _, _, let attachments, _)? = records.map(line).first else { Issue.record("no user message"); return }
        #expect(attachments.map(\.recordedImageID) == ["abc", "def"])
        #expect(attachments.map(\.name) == ["Photo", "cat.jpg"])
    }
}
