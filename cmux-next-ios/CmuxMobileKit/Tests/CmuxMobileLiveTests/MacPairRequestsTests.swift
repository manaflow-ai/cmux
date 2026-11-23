#if canImport(CmuxMobileLinkFFI)
@testable import CmuxMobileLive
import CmuxMobileTransport
import Foundation
import Testing

/// ask-45c37458ea (Leo, 2026-11-22: "ok surely we dont need to be bottled this hard by a click"):
/// another device waiting for a linked Mac's Allow shows as a card on the phone, and the phone's
/// Allow answers it on that Mac.
@MainActor
@Suite struct MacPairRequestsTests {
    static let fingerprintA = "1a2b3c4d5e6f7a8b"
    static let fingerprintB = "9c8d7e6f5a4b3c2d"

    static func listReply(_ rows: [(id: String, fingerprint: String)]) -> Data {
        let items = rows.map { #"{"deviceId":"\#($0.id)","name":"\#($0.id) iPhone","kind":"phone","fingerprint":"\#($0.fingerprint)","waitingMs":4000}"# }
        return Data(#"{"requests":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    /// Waits up to `seconds` for `condition` on the main actor.
    static func eventually(_ seconds: Double = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    static func source(_ box: LinkBox) -> MacPairRequests.Source {
        MacPairRequests.Source(link: { box.link }, name: { "Leo's Mac" }, capabilities: { ["pair-requests-v1"] })
    }

    @Test func aWaitingRequestShowsAndAllowAnswersItOnTheMac() async throws {
        let requests = MacPairRequests()
        let link = PairRequestsScriptLink(list: Self.listReply([("probe", Self.fingerprintA)]))
        let box = LinkBox(link)
        requests.linkServed(macID: "mac", source: Self.source(box))
        #expect(await Self.eventually { requests.cards.count == 1 })
        let card = try #require(requests.cards.first)
        #expect(card.request.deviceId == "probe")
        #expect(card.request.fingerprintShown == "1a2b 3c4d 5e6f 7a8b")
        #expect(card.macName == "Leo's Mac")

        link.list = Self.listReply([])
        requests.answer(card, allow: true)
        #expect(await Self.eventually { requests.cards.isEmpty })
        let answer = try #require(link.opened.first { $0["action"] == "answer" })
        #expect(answer == ["action": "answer", "deviceId": "probe", "fingerprint": Self.fingerprintA, "allow": "true"])
        requests.background()
    }

    /// A Mac's link replaced while a card shows: the new link is listed at once. Before, the old
    /// link's poll still held the Mac's slot, so the new link was never listed and its cards
    /// stayed away until the next foreground.
    @Test func aReplacedLinkIsListedAtOnce() async {
        let requests = MacPairRequests()
        let first = PairRequestsScriptLink(list: Self.listReply([("probe", Self.fingerprintA)]))
        let box = LinkBox(first)
        requests.linkServed(macID: "mac", source: Self.source(box))
        #expect(await Self.eventually { requests.cards.count == 1 })

        let second = PairRequestsScriptLink(list: Self.listReply([("probe", Self.fingerprintA), ("other", Self.fingerprintB)]))
        box.link = second
        requests.linkServed(macID: "mac", source: Self.source(box))
        // Well inside the 3 s while-shown poll: only a fresh poll on the new link lists it this soon.
        #expect(await Self.eventually(1) { requests.cards.count == 2 })
        #expect(second.opened.contains { $0["action"] == "list" })
        requests.background()
    }

    /// A Mac whose hostd has no `pair-requests` service shows nothing and is not asked again.
    @Test func anOlderHostdShowsNoCards() async {
        let requests = MacPairRequests()
        let link = PairRequestsScriptLink(list: nil)
        requests.linkServed(macID: "mac", source: Self.source(LinkBox(link)))
        #expect(await Self.eventually(0.5) { link.opened.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(requests.cards.isEmpty)
        #expect(link.opened.count == 1)
    }
}

@MainActor final class LinkBox {
    var link: (any MacLink)?
    init(_ link: any MacLink) { self.link = link }
}

/// A Mac's link whose `pair-requests` channel answers `list` with `list` (nil: refused as an
/// unknown service, an older hostd) and `answer` with `{"ok":true}`; it records each open's args.
final class PairRequestsScriptLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    private let lock = NSLock()
    private var listReply: Data?
    private var opens: [[String: String]] = []
    var opened: [[String: String]] { lock.withLock { opens } }
    var list: Data? {
        get { lock.withLock { listReply } }
        set { lock.withLock { listReply = newValue } }
    }

    init(list: Data?) {
        listReply = list
        states = AsyncStream { $0.finish() }
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let reply: Data? = lock.withLock {
            opens.append(args)
            return args["action"] == "answer" ? Data(#"{"ok":true}"#.utf8) : listReply
        }
        guard service == "pair-requests", let reply else {
            return PairRequestsScriptChannel(frames: [], closedBy: LinkError(code: "unknown_service", message: ""))
        }
        return PairRequestsScriptChannel(frames: [reply], closedBy: nil)
    }
    func ping() async throws -> UInt32 { 1 }
    func close() async {}
}

final class PairRequestsScriptChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    let closedBy: LinkError?
    private let lock = NSLock()
    private var frames: [Data]

    init(frames: [Data], closedBy: LinkError?) {
        self.frames = frames
        self.closedBy = closedBy
    }

    func send(_ data: Data) async throws {}
    func receive() async throws -> Data? {
        lock.withLock { frames.isEmpty ? nil : frames.removeFirst() }
    }
    func close(code: String, reason: String) async {}
}
#endif
