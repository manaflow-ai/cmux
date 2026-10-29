import Foundation
import Synchronization
import Testing
@testable import CmuxNextComputerUse

/// The app's half of the helper's machine-consent questions: it answers
/// from its own daemon, whatever the question carries.
struct ComputerUseHelperConsentTests {
    @Test func aDaemonAnswerPassesThroughAndNoAnswerFailsClosed() throws {
        let granted = Data(#"{"consentRequired":true,"consent":{"screen":"granted","control":"none"},"lastRefusal":null}"#.utf8)
        let line = try #require(try JSONSerialization.jsonObject(with: ComputerUseHelperV2Consent.answer(id: 7, result: granted)) as? [String: Any])
        #expect(line["type"] as? String == "machine_consent")
        #expect(line["id"] as? Int == 7)
        #expect(line["ok"] as? Bool == true)
        let result = try #require(line["result"] as? [String: Any])
        #expect(result["consentRequired"] as? Bool == true)
        #expect(result["consent"] as? [String: String] == ["screen": "granted", "control": "none"])

        for failed in [nil, Data("not json".utf8), Data("[]".utf8)] as [Data?] {
            let line = try #require(try JSONSerialization.jsonObject(with: ComputerUseHelperV2Consent.answer(id: 8, result: failed)) as? [String: Any])
            #expect(line["ok"] as? Bool == false)
            #expect(line["result"] == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func everyQuestionIsAskedOfTheDaemonAndNothingInItRedirects() async throws {
        let asked = Mutex(0)
        let refusals = Mutex<[String]>([])
        let (answers, continuation) = AsyncStream<Data>.makeStream()
        let send: @Sendable (Data) async -> Void = { continuation.yield($0) }
        let daemon: @Sendable () async -> Data? = {
            asked.withLock { $0 += 1 }
            return Data(#"{"consentRequired":true,"consent":{"screen":"none","control":"none"}}"#.utf8)
        }
        let refused: @Sendable (String) async -> Void = { surface in refusals.withLock { $0.append(surface) } }
        let question: [String: Any] = ["type": "machine_consent", "id": 3,
                                       "home": "/tmp/alternate", "socket": "/tmp/other.sock"]
        #expect(ComputerUseHelperV2Consent.handle(question, send: send, consent: daemon, refused: refused))
        #expect(ComputerUseHelperV2Consent.handle(["type": "machine_consent", "id": 4], send: send,
                                                  consent: daemon, refused: refused))
        var ids: Set<Int> = []
        for await answer in answers {
            let line = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
            ids.insert(try #require(line["id"] as? Int))
            let result = try #require(line["result"] as? [String: Any])
            #expect(result["consent"] as? [String: String] == ["screen": "none", "control": "none"])
            if ids.count == 2 { break }
        }
        #expect(ids == [3, 4])
        #expect(asked.withLock { $0 } == 2, "no answer is cached")

        #expect(ComputerUseHelperV2Consent.handle(["type": "consent_refused", "surface": "control"], send: send,
                                                  consent: daemon, refused: refused))
        #expect(!ComputerUseHelperV2Consent.handle(["type": "ack", "of": "register_acpmux"], send: send,
                                                   consent: daemon, refused: refused))
    }
}
