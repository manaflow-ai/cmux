import CmuxMobileAgentChat
import CmuxMobileTransport
import Compression
import Foundation
import Testing
@testable import CmuxMobileLive

/// CMUX-563: the phone is ready with the newest page of the Mac's chat list, reads the rest
/// after, and reads the large replies a Mac's mobile host sends compressed.
@MainActor
@Suite struct AcpmuxListPagesTests {
    nonisolated static func row(_ id: String, status: String = "idle") -> String {
        #"{"sessionId":"\#(id)","name":"\#(id)","harness":"fake","cwd":"/tmp/w","status":"\#(status)"}"#
    }

    nonisolated static func rows(_ range: Range<Int>) -> String {
        range.map { row("s\($0)") }.joined(separator: ",")
    }

    /// Rows whose previews differ (each a different run of digits), so their list deflates to
    /// more than one link chunk.
    nonisolated static func varied(_ range: Range<Int>) -> String {
        range.map { i in
            let preview = (0..<8).map { String(($0 + 1) &* 2_654_435_761 &* (i + 1) % 1_000_000_007, radix: 36) }.joined()
            return #"{"sessionId":"s\#(i)","name":"s\#(i)","harness":"fake","cwd":"/tmp/w","status":"idle","preview":"\#(preview)"}"#
        }.joined(separator: ",")
    }

    /// A Mac's acpmux channel whose later list pages wait until `release()`: the test sees what
    /// the hub does with the first page alone. Every request is recorded.
    final class HeldPagesChannel: LinkChannel, @unchecked Sendable {
        let id: UInt32 = 1
        private let lock = NSLock()
        private let inbox: AsyncStream<Data>
        private let continuation: AsyncStream<Data>.Continuation
        private var iterator: AsyncStream<Data>.AsyncIterator
        private var held: [Data] = []
        private var released = false
        private(set) var calls: [(String, [String: Any])] = []
        let watch: String
        let pages: [String: String]

        init(watch: String, pages: [String: String]) {
            self.watch = watch
            self.pages = pages
            (inbox, continuation) = AsyncStream.makeStream()
            iterator = inbox.makeAsyncIterator()
        }

        var methods: [String] { lock.withLock { calls.map(\.0) } }
        func params(_ method: String) -> [String: Any]? { lock.withLock { calls.first { $0.0 == method }?.1 } }

        func send(_ data: Data) async throws {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return }
            let id = object["id"].map { "\($0)" } ?? "null"
            let params = object["params"] as? [String: Any] ?? [:]
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            let answer: Data
            switch method {
            case "_acpmux/watch": answer = reply(watch)
            case "_acpmux/sessions": answer = reply(pages[params["cursor"] as? String ?? ""] ?? #"{"sessions":[]}"#)
            case "initialize": answer = reply(#"{"protocolVersion":1}"#)
            default: answer = reply("{}")
            }
            let hold = lock.withLock { () -> Bool in
                calls.append((method, params))
                guard method == "_acpmux/sessions", !released else { return false }
                held.append(answer)
                return true
            }
            if !hold { continuation.yield(answer) }
        }

        /// A notification from the Mac.
        func notify(_ method: String, _ params: String) {
            continuation.yield(Data(#"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"#.utf8))
        }

        func release() {
            let waiting = lock.withLock { () -> [Data] in
                released = true
                defer { held = [] }
                return held
            }
            for answer in waiting { continuation.yield(answer) }
        }

        func receive() async throws -> Data? { await iterator.next() }
        func close(code: String, reason: String) async { continuation.finish() }
    }

    /// How long a test waits for the hub to be ready: past the hub's own 20 s request timeout
    /// (`AcpmuxHub.bind`'s default), so a slow answer the hub still takes is not a failure, and a
    /// runner busy with the whole parallel suite only makes it slower. 5 s ran out on two CI
    /// runs (cmux#40617, #41225) whose changes did not touch the hub. A Mac that never answers
    /// still fails here, after the full wait (a failed bind does not end `waitUntilReady`).
    static let readyWait: Duration = .seconds(30)

    /// 250 chats: 100 on the watch's page, 100 and 50 after it.
    static func mac() -> HeldPagesChannel {
        HeldPagesChannel(
            watch: #"{"sessions":[\#(rows(0..<100))],"nextCursor":"c1"}"#,
            pages: ["c1": #"{"sessions":[\#(rows(100..<200))],"nextCursor":"c2"}"#,
                    "c2": #"{"sessions":[\#(rows(200..<250))],"nextCursor":null}"#]
        )
    }

    /// The hub's watch events from now on (installed before anything can send one), and
    /// waits on them. Main-actor state only: the hub calls `onWatchEvent` on the main actor.
    @MainActor
    final class Events {
        private var loaded: [Int] = []
        private var changed = 0
        private var waiters: [(check: () -> Bool, done: CheckedContinuation<Void, Never>)] = []

        init(_ hub: AcpmuxHub) {
            hub.onWatchEvent = { [weak self] event in
                guard let self else { return }
                switch event {
                case .sessionsLoaded(let sessions): self.loaded.append(sessions.count)
                case .sessionChanged: self.changed += 1
                default: break
                }
                let ready = self.waiters.filter { $0.check() }
                self.waiters.removeAll { $0.check() }
                for waiter in ready { waiter.done.resume() }
            }
        }

        private func wait(until check: @escaping () -> Bool) async {
            if check() { return }
            await withCheckedContinuation { waiters.append((check, $0)) }
        }

        /// Waits for a `sessionsLoaded` of at least `count` rows; the largest seen.
        func loaded(atLeast count: Int) async -> Int {
            await wait { self.loaded.contains { $0 >= count } }
            return loaded.max() ?? 0
        }

        /// Waits until `count` `session_changed` notices were applied.
        func told(_ count: Int) async {
            await wait { self.changed >= count }
        }
    }

    @Test func theHubIsReadyWithTheNewestPageAndReadsTheRestAfter() async throws {
        let mac = Self.mac()
        defer { mac.release() }
        let hub = AcpmuxHub()
        let events = Events(hub)
        let bound = Task { await hub.bind(mac) }
        // Ready while the later pages are still on their way.
        #expect(await hub.waitUntilReady(timeout: Self.readyWait, clock: ContinuousClock()))
        #expect(mac.params("_acpmux/watch")?["limit"] as? Int == 100)
        #expect(hub.sessions.count == 100)
        #expect(hub.sessions["s0"] != nil && hub.sessions["s120"] == nil)

        mac.release()
        #expect(await events.loaded(atLeast: 250) == 250)
        #expect(hub.sessions.count == 250)
        // The rest is read in pages, each with the cursor of the one before.
        #expect(mac.methods == ["initialize", "_acpmux/watch", "_acpmux/sessions", "_acpmux/sessions"])
        await bound.value
    }

    /// A chat a notice told while the rest was read keeps the notice's newer state, and one
    /// purged then does not come back with its page.
    @Test func noticesDuringTheRestWinOverItsPages() async throws {
        let mac = Self.mac()
        defer { mac.release() }
        let hub = AcpmuxHub()
        let events = Events(hub)
        let bound = Task { await hub.bind(mac) }
        #expect(await hub.waitUntilReady(timeout: Self.readyWait, clock: ContinuousClock()))
        mac.notify("_acpmux/session_changed", #"{"session":\#(Self.row("s150", status: "running")),"kind":"updated"}"#)
        mac.notify("_acpmux/session_changed", #"{"session":\#(Self.row("s160")),"kind":"purged"}"#)
        await events.told(2)
        mac.release()
        _ = await events.loaded(atLeast: 249)
        #expect(hub.sessions["s150"]?.status == "running")
        #expect(hub.sessions["s160"] == nil)
        #expect(hub.sessions.count == 249)
        await bound.value
    }

    /// An older acpmux answers the watch whole, with no cursor: one request, as before.
    @Test func aWholeWatchReplyIsTheList() async throws {
        let mac = HeldPagesChannel(watch: #"{"sessions":[\#(Self.rows(0..<3))]}"#, pages: [:])
        let hub = AcpmuxHub()
        await hub.bind(mac)
        #expect(hub.isReady)
        #expect(hub.sessions.count == 3)
        #expect(!mac.methods.contains("_acpmux/sessions"))
    }

    // MARK: Compressed replies

    /// The envelope the Mac's mobile host sends (`link_deflate.rs`), made with the system's raw deflate.
    nonisolated static func envelope(_ text: Data) -> Data {
        var out = Data(count: text.count + 1024)
        let written = out.withUnsafeMutableBytes { dst in
            text.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, text.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, text.count, nil, COMPRESSION_ZLIB)
            }
        }
        out.count = written
        func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
        return Data([0x00]) + u32(text.count) + u32(written) + out
    }

    /// A Mac whose replies of 16 KiB or more come as envelopes, written in the link's 16 KiB chunks.
    nonisolated static func compressingMac(_ answer: @escaping @Sendable (String) -> String) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            let text = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(answer(method))}"#.utf8)
            guard text.count >= 16 << 10 else { return [text] }
            let bytes = envelope(text)
            let chunk = AcpmuxConnection.MessageJoiner.chunk
            return stride(from: 0, to: bytes.count, by: chunk).map { bytes.subdata(in: $0..<min($0 + chunk, bytes.count)) }
        }
    }

    @Test func aCompressedListIsReadWhole() async throws {
        let mac = Self.compressingMac { method in
            method == "_acpmux/watch" ? #"{"sessions":[\#(Self.varied(0..<2000))]}"# : "{}"
        }
        // The envelope spans several link chunks, so the joiner reads one across frames.
        let text = Data(#"{"jsonrpc":"2.0","id":1,"result":{"sessions":[\#(Self.varied(0..<2000))]}}"#.utf8)
        #expect(Self.envelope(text).count > AcpmuxConnection.MessageJoiner.chunk)
        let connection = AcpmuxConnection(channel: try await mac.openChannel(service: "acpmux", args: ["compression": "deflate"]))
        let rows = try await connection.wholeList("_acpmux/watch", ["enabled": .bool(true)], timeout: .seconds(5))
        #expect(rows.count == 2000)
        #expect(rows.last?["sessionId"]?.stringValue == "s1999")
        // Text replies still read after an envelope.
        let small = try await connection.request("initialize", .object([:]), timeout: .seconds(5))
        #expect(small == .object([:]))
    }

    /// An envelope the Mac's mobile host made (flate2 1.1.9 `DeflateEncoder`, `Compression::fast()`,
    /// `link_deflate::envelope`) of `{"id":7,"jsonrpc":"2.0","result":{"sessions":[400 rows]}}`:
    /// the phone reads hostd's own bytes, not only the system encoder's.
    static let hostEnvelopeHex = [
        "0000005544000008b78ddcdd8a5cd71585d15709752d42d739fda77e833c43c88570047170e4e096af84de3dadb1db50",
        "b34ebc66dd7ed1d0e9b026026f237f3bfdfccfd3cbd387d3bf5f7ffdf2db7f7f3abd9cb6bfde9d3e9c7efbfcfafb2f5f",
        "4f2fdf4eaf9f5f5f7ffef5cbebe9e5efdf4e5f3efde7f3dbaff9e95f9fbefee5c72f7bff1ffff6f69b9c5e85af9fbefe",
        "fef66bdf7edf5f3e9fbe7f48727efb9d830823d9ae893092fd9a0823b9bf26c2481eae893092c76b228ce4e99a082379",
        "be26c2483e5e13612467d75edb58e75f6546ee1d4899918b075266e4e6819419b97a206546ee1e489991cb075266e4f6",
        "819419b97e206546ee1f4819d17658c42a3372ffcb2f6dca8cdc3f903223f70fa4ccc8fd03293372ff40ca8cdc3f9032",
        "23f70fa4ccc8fd03293372ff40ca88f6c322569991fb5f7e695766e4fe819419b97f206546ee1f489991fb075266e4fe",
        "819419b97f206546ee1f489991fb075246747f58c42a3372ffcb2fdd2b3372ff40ca8cdc3f903223f70fa4ccc8fd0329",
        "3372ff40ca8cdc3f903223f70fa4ccc8fd0329237a382c629519b9ffe5971e9419b97f206546ee1f489991fb075266e4",
        "fe819419b97f206546ee1f489991fb075266e4fe8194113d1e16b1ca8cdcfff24b8fca8cdc3f903223f70fa4ccc8fd03",
        "293372ff40ca8cdc3f903223f70fa4ccc8fd03293372ff40ca889e0e8b586546ee7ff9a5276546ee1f489991fb075266",
        "e4fe819419b97f206546ee1f48f981fef49fd49fdc3f903223f70fa4ccc8fd0329237a3e2c629519b9ffe5979e9519b9",
        "7f206546ee1f489991fb075266e4fe819419b97f206546ee1f489991fb075266e4fe8194117d3c2c629519b9ffe5973e",
        "2a3372ff40ca8cdc3f903223f70fa4ccc8fd03293372ff40ca8cdc3f903223f70fa4ccc8fd0329233adf1d26f19e0a33",
        "81cb8f9defa4c28c209954981924930a3384645261a6904c2acc18924985994332a930834826156612c9a499ad67cb60",
        "2b156612c9a4c24c229954984924930a338964526126914c2acc24924985994432a930934826156612c9a499ada7cc60",
        "2b156612c9a4c24c229954984924930a338964526126914c2acc24924985994432a930934826156612c9a499ade7cd60",
        "2b156612c9a4c24c229954984924930a338964526126914c2acc24924985994432a930934826156612c9a499ad27cf60",
        "2b156612c9a4c24c229954984924930a338964526126914c2acc24924985994432a930934826156612c9a499ad67d060",
        "2b156612c9a4ffcbfef877f9e787edfa5f01bfa7c24c22bf26156612c9a4c24c229954984924930a338964526126914c",
        "2acc249249335b4fa3c1562acc249249851d57f228156612f935a930934826156612c9a4c24c229954984924930a3389",
        "64526126914c9ad97a2e0db65261e7c31f0a37bca19e9f4c22bf2695af994432a930934826156612c9a4c24c22995498",
        "4924930a338964526126914c9ad9f3dde1dc2b15765cc90defaae76793881f72a5f235934826156612c9a4c24c229954",
        "984924930a338964526126914c2acc249249335bcfaac1562aecb8921bde5acf1f8f2b59a97ccd24f287940a33896452",
        "6126914c2acc24924985994432a930934826156612c9a4916dc7b7d7f754d86125db0d6fafdbdd6125efa97ccd242eff",
        "bf6d77526126914c2acc24924985994432a9b0a7eb3fccb73ba93093c8af49859944326966eba135d84a851d5772960a",
        "3baee42c156612f9434a85994432a93093482615f67838f7592acc24f26b526126914c2acc249249335b0fadc1562acc",
        "24924985994432a930934826156612c9a4c24c22995498495cb0d76d930a338964526126914c2acc249249335b0fadc1",
        "562acc24924985994432a930934826156612c9a4c24c229954984924930a338964526126914c2acc249249335b0fadc1",
        "562acc24924985994432a930934826156612c9a4c24c229954984924930a338964526126914c2acc249249335b0fadc1",
        "562acc24924985994432a930934826156612c9a4c24c229954984924930a338964526126914c2acc249249335b0fadc1",
        "562acc24924985994432a930934826156612c9a4c24c229954984924930a338964526126914c2acc249249335b0fadc1",
        "562acc24924985994432a930934826156612c9a4c24c229954984924930a338964526126914c2acc249249337b3ebcbd",
        "6e2b156612f1b51bde5eb76793482695af994432a930934826156612c9a4c24c229954984924930a338964526126914c",
        "9ad97a680db65261c795dcf0f6baad87d6fcda0d2bf96812c9a4f2439a4432a930934826156612c9a4c24c2299549849",
        "24930a338964d2c8f6e3dbeb7b3ab28bbfcebfaf87d6cbafbda7c24c229954984924930a338964526126914c2acc2492",
        "4985994432a930934826156612c9a499ad87d6602b1576f8b364bfe1ed753f9b447e4d2a5f338964526126914c2acc24",
        "9249853d5ebfbdee37bcbdee6793c8af49e56b26914c2acc249249335b0fadc1562aecb8921bfe5effbe99447e4d2a5f",
        "338964526126914c2aece170ee4d2aecb8921bde5ef7cd24f28794cad74c2299549849249366b61e5a83ad54d87125b7",
        "fc5dffdd24f26b52f99a4924930abb3f9c7b970a3389fc9a54d87125bb549849e4d7a4c24c2299549849249366b61e5a",
        "83ad54d8712537fcfdfffdde24f26b52f9da7e38f7bd549849e4d7a4c24c229954984924930a338964526126914c2acc",
        "249249335b0fadc1562aecb8921bfe9b00fbc37638f7c3f62395af9944fe90526126914c2acc24924985994432a93093",
        "4826156612c9a4c24c229934b3f5d01a6ca5c28e2bb9e1bf13b03f9a447e4d2a5f338964526126914c2acc2492498599",
        "4432a930934826156612c9a4c24c229934b3f5d01a6ca5c2ce3ffe044826156612c9a4c24c229954984924930a33893f",
        "d8e9e5f4ba3f4985994432a930934826156612c9a4c24c229934b3f5d01a6ca5c24c229954984924930a338964526126",
        "914c2acc24924985994432a930934826156612c9a4c24c229934b3f5d01a6ca5c24c229954984924930a338964526126",
        "914c2acc24924985994432a930934826156612c9a4c24c229994ec1fdfbfff0f",
    ].joined()

    @Test func aHostEnvelopeDecodes() throws {
        let digits = Array(Self.hostEnvelopeHex)
        var bytes = Data()
        for at in stride(from: 0, to: digits.count, by: 2) {
            bytes.append(try #require(UInt8(String(digits[at..<at + 2]), radix: 16)))
        }
        #expect(bytes.first == 0x00)
        var joiner = AcpmuxConnection.MessageJoiner()
        let chunk = AcpmuxConnection.MessageJoiner.chunk
        var value: JSONValue?
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            value = joiner.push(bytes.subdata(in: start..<min(start + chunk, bytes.count)))
        }
        let rows = try #require(value?["result"]?["sessions"]?.arrayValue)
        #expect(rows.count == 400)
        #expect(rows.last?["sessionId"]?.stringValue == "s399")
    }

    /// An envelope that inflates to more or less than its header says is refused, and the
    /// next message still reads.
    @Test func anEnvelopeThatLiesAboutItsLengthIsRefused() {
        var joiner = AcpmuxConnection.MessageJoiner()
        let text = Data(#"{"jsonrpc":"2.0","method":"x","params":{"pad":"\#(String(repeating: "a", count: 40_000))"}}"#.utf8)
        var bytes = Self.envelope(text)
        bytes[4] &+= 1  // text length one more than the stream holds
        #expect(joiner.push(bytes) == nil)
        #expect(joiner.push(Data(#"{"jsonrpc":"2.0","method":"y"}"#.utf8))?["method"]?.stringValue == "y")
        #expect(joiner.push(Self.envelope(text))?["method"]?.stringValue == "x")
    }
}
