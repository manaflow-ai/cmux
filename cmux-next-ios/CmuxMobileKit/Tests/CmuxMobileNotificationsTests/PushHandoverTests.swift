import Foundation
import Testing
@testable import CmuxMobileNotifications

/// "I tap a multiple choice answer on cmux NEXT iOS and nothing happens" (2026-11-04): a
/// device build has no App Group, so the long look's option rows had no outbox and opened the
/// app with the answer dropped. The push keychain group, which every build has, carries it.
@Suite struct PushHandoverTests {
    let question = PushPayload(mac: "m", macName: "Mac", kind: .question, eventId: "e", sessionId: "s", permissionId: "p",
                               questions: [PushQuestion(question: "Which fleet issue?", options: [.init(label: "Failing PR check"), .init(label: "Stuck build job")])])

    @Test func aTappedOptionReachesTheAppOnce() throws {
        let handover = PushHandover(store: PushMemoryStore())
        let reply = try #require(PushReply(payload: question, action: .option(1, label: "Stuck build job")))
        try handover.put(reply, requestID: "request-1")
        #expect(handover.take(requestID: "request-2") == nil, "another notification's open takes nothing")
        #expect(handover.take(requestID: "request-1") == reply)
        #expect(handover.take(requestID: "request-1") == nil, "taken once")
    }

    @Test func aStaleReplyIsDropped() throws {
        let handover = PushHandover(store: PushMemoryStore())
        let now = Date()
        let reply = try #require(PushReply(payload: question, action: .option(0, label: "Failing PR check"), now: now))
        try handover.put(reply, requestID: "r")
        #expect(handover.take(requestID: "r", now: now.addingTimeInterval(PushOutbox.maxAge + 1)) == nil)
    }

    /// PR B review H2, as for the outbox: text is never typed into a terminal from a handover.
    @Test func terminalTextIsRefused() {
        let handover = PushHandover(store: PushMemoryStore())
        let reply = PushReply(mac: "m", kind: .terminal, notificationId: "1", action: .text("y", attachments: []))
        #expect(throws: PushOutbox.Refused.self) { try handover.put(reply, requestID: "r") }
    }
}
