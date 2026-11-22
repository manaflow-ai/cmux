import Foundation
import Testing
@testable import CMUXMobileCore

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7):
/// every decoder that reads bytes from the network (a paired Mac or phone,
/// a relay) returns a value or a typed error for any input and never traps.
/// Seeded mutation of valid encodings plus random bytes; a trap fails the run.
@Suite struct MobileProtocolFuzzTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static func mutate(_ data: Data, _ rng: inout Rng) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<(1 + rng.below(4)) {
            switch rng.below(5) {
            case 0 where !bytes.isEmpty: bytes[rng.below(bytes.count)] = UInt8(truncatingIfNeeded: rng.next())
            case 1 where !bytes.isEmpty: bytes.removeSubrange(rng.below(bytes.count)...)
            case 2: bytes.insert(UInt8(truncatingIfNeeded: rng.next()), at: rng.below(bytes.count + 1))
            case 3 where bytes.count > 1: bytes.swapAt(rng.below(bytes.count), rng.below(bytes.count))
            default: bytes += bytes.prefix(rng.below(bytes.count + 1))
            }
        }
        return Data(bytes)
    }

    static func random(_ rng: inout Rng, _ limit: Int = 64) -> Data {
        Data((0..<rng.below(limit)).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }

    @Test func terminalInputFramesRoundTripAndAnyBytesDecodeOrThrow() throws {
        var rng = Rng(state: 0x51)
        for _ in 0..<2_000 {
            let text = String(decoding: Self.random(&rng, 40).map { $0 % 94 + 32 }, as: UTF8.self) + "é👩‍👩‍👧"
            let frame = MobileTerminalInputFrame(text: text, sequence: rng.below(2) == 0 ? rng.next() : nil)
            var whole = try frame.encoded()
            #expect(try MobileTerminalInputFrame.decode(from: &whole) == [frame])
            var mutated = Self.mutate(try frame.encoded(), &rng)
            _ = try? MobileTerminalInputFrame.decode(from: &mutated)
            var noise = Self.random(&rng)
            _ = try? MobileTerminalInputFrame.decode(from: &noise)
        }
    }

    @Test func syncFramesDecodeOrThrowForAnyBytes() throws {
        var rng = Rng(state: 0x52)
        for _ in 0..<2_000 {
            var stream = Data()
            for _ in 0..<rng.below(4) { stream += try MobileSyncFrameCodec.encodeFrame(Self.random(&rng, 32)) }
            var mutated = Self.mutate(stream, &rng)
            _ = try? MobileSyncFrameCodec.decodeFrames(from: &mutated, maximumFrameByteCount: 64,
                                                      maximumDecodedFrameCount: 1 + rng.below(4))
            var noise = Self.random(&rng)
            _ = try? MobileSyncFrameCodec.decodeFrames(from: &noise)
        }
    }

    static let grid = Data(#"""
    {"format":"cmux.render-grid.v1","surface_id":"fuzz","state_seq":1,"columns":4,"rows":2,"full":true,
     "styles":[{"id":0,"foreground":"#FDFFF1","background":"#272822","foreground_source":"default","background_source":"default"}],
     "row_spans":[{"row":0,"column":0,"style_id":0,"cell_width":4,"text":"test"},{"row":1,"column":1,"style_id":0,"cell_width":2,"text":"日"}]}
    """#.utf8)

    /// A screen-anchored delta that scrolled and carries scrollback, so the
    /// mutations reach scrolled_rows, scrollback_rows and the cursor.
    static let scrolledDelta = Data(#"""
    {"format":"cmux.render-grid.v1","surface_id":"fuzz","state_seq":2,"columns":4,"rows":2,"full":false,"anchor":"screen",
     "scrolled_rows":1,"scrollback_rows":1,"cleared_rows":[0],"cursor":{"row":1,"column":2},
     "styles":[{"id":0,"foreground":"#FDFFF1","background":"#272822","foreground_source":"default","background_source":"default"}],
     "row_spans":[{"row":0,"column":0,"style_id":0,"cell_width":4,"text":"test"}],
     "scrollback_spans":[{"row":0,"column":0,"style_id":0,"cell_width":2,"text":"ab"}]}
    """#.utf8)

    @Test(arguments: [grid, scrolledDelta])
    func renderGridFramesFromMutatedJSONDecodeAndReplayOrThrow(_ base: Data) throws {
        _ = try MobileTerminalRenderGridFrame.decode(base)  // the base itself decodes
        let object = try #require(try JSONSerialization.jsonObject(with: base) as? [String: Any])
        let extremes: [Any] = [Int.max, Int.min, -1, 0, 1, 4_097, 20_001, 65_536, 1e300, "", "#", "#GGGGGG", NSNull(), [Any](), [String: Any]()]
        var rng = Rng(state: 0x53)
        var decoded = 0
        for _ in 0..<3_000 {
            // One or two fields per frame, so most frames still decode and reach the replay.
            var copy = object
            for _ in 0..<(1 + rng.below(2)) {
                let keys = copy.keys.sorted()
                let key = keys[rng.below(keys.count)]
                if var spans = copy[key] as? [[String: Any]], !spans.isEmpty, rng.below(2) == 0 {
                    let i = rng.below(spans.count)
                    let spanKeys = spans[i].keys.sorted()
                    spans[i][spanKeys[rng.below(spanKeys.count)]] = extremes[rng.below(extremes.count)]
                    copy[key] = spans
                } else {
                    copy[key] = extremes[rng.below(extremes.count)]
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: copy) else { continue }
            for input in [data, Self.mutate(data, &rng)] {
                if let frame = try? MobileTerminalRenderGridFrame.decode(input) {
                    decoded += 1
                    _ = frame.vtPatchBytes()
                    _ = frame.vtReplacementBytes()
                }
            }
        }
        #expect(decoded > 100, "the mutations must also produce frames that decode")
    }

    @Test func renderGridSizeLimitsAcceptTheMaximumAndRefuseOnePast() throws {
        func frame(_ fields: String) -> Data {
            Data(#"{"format":"cmux.render-grid.v1","surface_id":"l","state_seq":1,"full":true,"row_spans":[],\#(fields)}"#.utf8)
        }
        let max = MobileTerminalRenderGridFrame.maximumDimension
        _ = try MobileTerminalRenderGridFrame.decode(frame(#""columns":\#(max),"rows":2"#))
        #expect(throws: MobileTerminalRenderGridError.self) {
            try MobileTerminalRenderGridFrame.decode(frame(#""columns":\#(max + 1),"rows":2"#))
        }
        let scrollback = MobileTerminalRenderGridFrame.maximumScrollbackRows
        _ = try MobileTerminalRenderGridFrame.decode(frame(#""columns":80,"rows":24,"scrollback_rows":\#(scrollback)"#))
        #expect(throws: MobileTerminalRenderGridError.self) {
            try MobileTerminalRenderGridFrame.decode(frame(#""columns":80,"rows":24,"scrollback_rows":\#(scrollback + 1)"#))
        }
        // Wide and tall within each limit, but past the replay's cell budget.
        #expect(throws: MobileTerminalRenderGridError.self) {
            try MobileTerminalRenderGridFrame.decode(frame(#""columns":\#(max),"rows":\#(max),"scrollback_rows":\#(scrollback)"#))
        }
        let delta = #"{"format":"cmux.render-grid.v1","surface_id":"l","state_seq":1,"full":false,"anchor":"screen","columns":4,"rows":2,"row_spans":[],"scrollback_rows":1,"scrolled_rows":"#
        _ = try MobileTerminalRenderGridFrame.decode(Data((delta + "3}").utf8))
        #expect(throws: MobileTerminalRenderGridError.self) {
            try MobileTerminalRenderGridFrame.decode(Data((delta + "\(Int.max)}").utf8))
        }
    }

    @Test func attachTicketsDecodeOrThrowForAnyBytes() {
        var rng = Rng(state: 0x54)
        let coder = CmxAttachTicketCompactCoder()
        for _ in 0..<2_000 {
            _ = try? coder.decode(Self.random(&rng, 200))
            _ = try? coder.decode(Self.mutate(Data(#"{"v":1,"h":"x","p":1}"#.utf8), &rng))
        }
    }

    /// Mac timestamps come from the wire. Any four timestamps give a split or nil;
    /// a round trip past Int64.max used to trap in the uplink clamp.
    @Test func clockOffsetSplitsAnyTimestampsOrRefuses() {
        var rng = Rng(state: 0x55)
        var estimator = MobileTerminalClockOffsetEstimator()
        let edges: [UInt64] = [0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max]
        for _ in 0..<2_000 {
            func pick() -> UInt64 { rng.below(3) == 0 ? edges[rng.below(edges.count)] : rng.next() }
            let t1 = pick(), t4 = pick(), receive = pick() / 1_000, dispatch = pick() / 1_000
            guard let split = estimator.observe(
                phoneSendNanos: min(t1, t4), macReceiveMicros: min(receive, dispatch),
                macDispatchMicros: max(receive, dispatch), phoneReceiveNanos: max(t1, t4)
            ) else { continue }
            #expect(split.uplinkNanos <= split.roundTripNanos)
            #expect(split.uplinkNanos + split.downlinkNanos == split.roundTripNanos)
        }
        var fresh = MobileTerminalClockOffsetEstimator()
        let huge = fresh.observe(
            phoneSendNanos: 0, macReceiveMicros: 5, macDispatchMicros: 5, phoneReceiveNanos: .max
        )
        #expect(huge?.roundTripNanos == .max)
    }

    @Test func deliveryIdentitiesAndAcknowledgementsRoundTripAndAnyBytesDecodeOrRefuse() {
        var rng = Rng(state: 0x56)
        for _ in 0..<2_000 {
            let delivery = MobileTerminalInputDelivery(surfaceID: UUID(), streamID: UUID(), sequence: rng.next())
            #expect(MobileTerminalInputDelivery(decoding: delivery.encoded()) == delivery)
            let status = MobileTerminalInputAcknowledgement.Status(rawValue: UInt8(1 + rng.below(7))) ?? .applied
            let ack = MobileTerminalInputAcknowledgement(
                status: status, streamID: UUID(), sequence: rng.next(), expected: rng.next()
            )
            #expect(MobileTerminalInputAcknowledgement(decoding: ack.encoded()) == ack)
            _ = MobileTerminalInputDelivery(decoding: Self.mutate(delivery.encoded(), &rng))
            _ = MobileTerminalInputAcknowledgement(decoding: Self.mutate(ack.encoded(), &rng))
            _ = MobileTerminalInputDelivery(decoding: Self.random(&rng, 48))
            _ = MobileTerminalInputAcknowledgement(decoding: Self.random(&rng, 48))
        }
    }

    /// Whole frames get a marker each; a malformed tail is forwarded unchanged.
    @Test func laneScopingKeepsEveryByteForAnyBlock() throws {
        var rng = Rng(state: 0x57)
        let scope = MobileEventLaneScope()
        let surface = UUID()
        let marker = scope.marker(surfaceID: surface)
        for _ in 0..<2_000 {
            var block = Data()
            var frames = 0
            for _ in 0..<rng.below(4) {
                block += try MobileSyncFrameCodec.encodeFrame(Self.random(&rng, 32))
                frames += 1
            }
            let scoped = scope.scoped(block, surfaceID: surface.uuidString)
            #expect(scoped.count == block.count + frames * marker.count)
            let mutated = Self.mutate(block, &rng)
            #expect(scope.scoped(mutated, surfaceID: surface.uuidString).count >= mutated.count)
            _ = scope.markerScope(inPayload: Self.random(&rng, 20))
        }
    }

    /// Address parsers read hosts and ports a user typed or a peer sent.
    @Test func addressParsersAcceptOrRefuseAnyText() throws {
        var rng = Rng(state: 0x58)
        let seeds = ["[::1]:80", "10.0.0.4:49152", "[fe80::1%en0]:1", "1.2.3.4", "[", "]:", "[]:", ":", "::", "[::1]",
                     "100.64.0.1", "fd7a:115c:a1e0::53", "a:b:c", "300.1.1.1:1", "1.1.1.1:65536", "1.1.1.1:0"]
        let qr = CmxPairingQRCode()
        let loopback = CmxLoopbackHost()
        for _ in 0..<3_000 {
            let seed = Data(seeds[rng.below(seeds.count)].utf8)
            let text = String(decoding: rng.below(4) == 0 ? Self.random(&rng, 24) : Self.mutate(seed, &rng), as: UTF8.self)
            _ = try? CmxIrohLocalSocketAddress(text)
            var pairing = URLComponents()
            pairing.scheme = "cmux"
            pairing.host = "pair"
            pairing.queryItems = [URLQueryItem(name: "v", value: "2"), URLQueryItem(name: "r", value: text)]
            _ = try? qr.decode(pairing)
            _ = loopback.matches(text)
            _ = CmxTailscalePeerAddress(text)
            _ = try? CmxIrohPathHint(kind: .directAddress, value: text, source: .native, privacyScope: .publicInternet)
        }
        #expect(try CmxIrohLocalSocketAddress("[fd00::1]:4000").port == 4000)
    }
}
