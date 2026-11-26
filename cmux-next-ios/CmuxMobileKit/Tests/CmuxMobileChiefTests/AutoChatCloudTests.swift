import Foundation
import Testing
@testable import CmuxMobileChief

/// The account's Auto chat calls at the HTTP boundary: what leaves the phone, and what it makes
/// of the answers. They share ``AccountCloudTests``'s scripted service, so they run in its suite.
extension AccountCloudTests {
    @Test func autoChatCallsGoOutAsTheAccountAndAnswerAsTheyCame() async throws {
        Service.reset(["/v1/auto-sessions/a1/events": (200, #"{"events":[],"last_seq":3}"#),
                       "/v1/auto-sessions/a1/inbox": (409, #"{"error":{"code":"session_closed"}}"#)])
        let account = Self.account()
        let read = try await account.autoChats("GET", "/v1/auto-sessions/a1/events?after=3", body: nil, timeout: 30)
        #expect(read.status == 200)
        #expect(String(decoding: read.body, as: UTF8.self) == #"{"events":[],"last_seq":3}"#)
        let seen = Service.lock.withLock { Service.seen.last }
        #expect(seen?.path == "/v1/auto-sessions/a1/events")
        #expect(seen?.query == "after=3")
        // A refusal is an answer: the caller reads its status and code, nothing is thrown.
        let refused = try await account.autoChats("POST", "/v1/auto-sessions/a1/inbox",
                                                  body: Data(#"{"id":"m1","text":"go"}"#.utf8), timeout: 20)
        #expect(refused.status == 409)
        #expect(String(decoding: refused.body, as: UTF8.self).contains("session_closed"))
        let sent = Service.lock.withLock { Service.seen.last }
        #expect(sent?.body["id"] as? String == "m1")
    }

    @Test func aPathOutsideTheAutoChatRoutesIsNeverSent() async {
        Service.reset([:])
        let account = Self.account()
        for path in ["/v1/ops", "/v1/auto-sessionsX", "/v1/auto-sessions/../ops", "/v1/auto-sessions/%2e%2e/ops",
                     "https://example.com/v1/auto-sessions"] {
            await #expect(throws: AccountCloud.Failure.badReply) {
                _ = try await account.autoChats("POST", path, body: nil, timeout: 20)
            }
        }
        #expect(Service.lock.withLock { Service.seen.isEmpty })
    }
}
