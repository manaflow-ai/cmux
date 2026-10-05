import Foundation
import Testing

@testable import CmuxBrowser

/// A network event is a read of the document that sent the request: it
/// reaches a session only when that session's authority allows that
/// document, and in the order the events happened.
@MainActor
@Suite("Browser REPL network event gate")
struct BrowserReplNetworkGateTests {
    /// The frame-tree read the gate asks for, answered when the test says.
    @MainActor
    private final class Reads {
        var documents: [String: BrowserReplFrameDocument] = [:]
        var count = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        var holds = false

        func read() async -> [String: BrowserReplFrameDocument] {
            count += 1
            if holds { await withCheckedContinuation { parked.append($0) } }
            return documents
        }

        func release() {
            holds = false
            let waiting = parked
            parked = []
            waiting.forEach { $0.resume() }
        }
    }

    private static let allowed = BrowserReplFrameDocument(origin: "https://allowed.test", place: "https://allowed.test")
    private static let blocked = BrowserReplFrameDocument(origin: "https://evil.test", place: "https://evil.test")

    private let reads = Reads()
    private var delivered: [String: [String]] { log.value }
    private let log = Log()

    @MainActor
    private final class Log {
        var value: [String: [String]] = [:]
    }

    /// Session "strict" prohibits evil.test; "open" has no policy.
    private func gate() throws -> BrowserReplNetworkGate<String> {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = [try BrowserReplDomainPattern.parse("evil.test", title: "t")]
        let reads = reads
        let log = log
        return BrowserReplNetworkGate<String>(
            tab: { BrowserReplTabFacts(mainFrameURL: URL(string: "https://allowed.test/")) },
            authority: { BrowserReplDocumentAuthority(sessionID: $0, policy: $0 == "strict" ? policy : BrowserReplDomainPolicy()) },
            readDocuments: { await reads.read() },
            deliver: { event, sessions in
                for session in sessions { log.value[session, default: []].append(event) }
            }
        )
    }

    @Test func anEventFromADocumentTheSessionsPolicyBlocksDoesNotReachIt() async throws {
        reads.documents = ["doc-allowed": Self.allowed, "doc-evil": Self.blocked]
        let gate = try gate()
        gate.send("from evil", from: BrowserReplNetworkSender(documentID: "doc-evil"), to: ["strict", "open"])
        gate.send("from allowed", from: BrowserReplNetworkSender(documentID: "doc-allowed"), to: ["strict", "open"])
        await gate.idle()
        #expect(delivered["strict"] == ["from allowed"])
        #expect(delivered["open"] == ["from evil", "from allowed"])
    }

    @Test func aDocumentLoadOfABlockedURLDoesNotReachTheSession() async throws {
        reads.documents = ["doc-allowed": Self.allowed]
        let gate = try gate()
        gate.send("navigate", from: BrowserReplNetworkSender(documentID: "doc-allowed", loadsDocument: "https://evil.test/x"), to: ["strict", "open"])
        await gate.idle()
        #expect(delivered["strict"] == nil)
        #expect(delivered["open"] == ["navigate"])
    }

    @Test func anEventWhoseDocumentCannotBeToldIsDroppedForAnActivePolicyOnly() async throws {
        let gate = try gate()
        gate.send("unknown", from: BrowserReplNetworkSender(documentID: "doc-gone"), to: ["strict", "open"])
        gate.send("no id", from: BrowserReplNetworkSender(documentID: nil), to: ["strict", "open"])
        await gate.idle()
        #expect(delivered["strict"] == nil)
        #expect(delivered["open"] == ["unknown", "no id"])
    }

    @Test func eventsWaitingForTheirDocumentKeepTheirOrder() async throws {
        let gate = try gate()
        reads.holds = true
        // The first event's document is not known yet: the tree is read,
        // and the next event, whose document the read will name too, waits
        // behind it.
        gate.send("first", from: BrowserReplNetworkSender(documentID: "doc-new"), to: ["strict"])
        gate.send("second", from: BrowserReplNetworkSender(documentID: "doc-new"), to: ["strict"])
        #expect(delivered["strict"] == nil)
        reads.documents = ["doc-new": Self.allowed]
        reads.release()
        await gate.idle()
        #expect(delivered["strict"] == ["first", "second"])
        // A document read once is known: no further read for it.
        let readsSoFar = reads.count
        gate.send("third", from: BrowserReplNetworkSender(documentID: "doc-new"), to: ["strict"])
        await gate.idle()
        #expect(delivered["strict"] == ["first", "second", "third"])
        #expect(reads.count == readsSoFar)
    }
}
