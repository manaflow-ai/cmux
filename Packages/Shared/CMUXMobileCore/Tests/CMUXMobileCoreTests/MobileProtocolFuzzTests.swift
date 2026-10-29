import CmuxFuzzSupport
import Foundation
import Testing
@testable import CMUXMobileCore

/// Crash program phase 3 (plans/cmux-next/crash-elimination.md section 7):
/// every decoder that reads bytes from the network (a paired Mac or phone,
/// a relay) returns a value or a typed error for any input and never traps.
/// Seeded mutation of valid encodings plus random bytes; a trap fails the run.
/// Seeded property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@Suite struct MobileProtocolFuzzTests {
    static func mutate(_ data: Data, _ rng: inout FuzzRNG) -> Data {
        FuzzMutator().mutate(data, using: &rng)
    }

    static func random(_ rng: inout FuzzRNG, _ limit: Int = 64) -> Data {
        rng.bytes(limit)
    }

    /// One input of a decoder property, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(8) {
        case 0: try terminalInputFrame(&rng)
        case 1: try syncFrames(&rng)
        case 2:
            let base = rng.bool() ? grid : scrolledDelta
            _ = renderGridFrame(object: try renderGridObject(base), &rng)
        case 3: attachTicket(&rng)
        case 4:
            var estimator = MobileTerminalClockOffsetEstimator()
            for _ in 0..<8 { try clockOffset(&estimator, &rng) }
        case 5: try deliveryAndAcknowledgement(&rng)
        case 6: try laneScoping(&rng)
        default: addressText(&rng)
        }
    }

    static func terminalInputFrame(_ rng: inout FuzzRNG) throws {
        let text = String(decoding: random(&rng, 40).map { $0 % 94 + 32 }, as: UTF8.self) + "é👩‍👩‍👧"
        let frame = MobileTerminalInputFrame(text: text, sequence: rng.below(2) == 0 ? rng.next() : nil)
        var whole = try frame.encoded()
        let decoded = try MobileTerminalInputFrame.decode(from: &whole)
        try FuzzRun.check(decoded == [frame], "an input frame did not round-trip")
        var mutated = mutate(try frame.encoded(), &rng)
        _ = try? MobileTerminalInputFrame.decode(from: &mutated)
        var noise = random(&rng)
        _ = try? MobileTerminalInputFrame.decode(from: &noise)
    }

    static func syncFrames(_ rng: inout FuzzRNG) throws {
        var stream = Data()
        for _ in 0..<rng.below(4) { stream += try MobileSyncFrameCodec.encodeFrame(random(&rng, 32)) }
        var mutated = mutate(stream, &rng)
        _ = try? MobileSyncFrameCodec.decodeFrames(from: &mutated, maximumFrameByteCount: 64,
                                                  maximumDecodedFrameCount: 1 + rng.below(4))
        var noise = random(&rng)
        _ = try? MobileSyncFrameCodec.decodeFrames(from: &noise)
    }

    @Test func terminalInputFramesRoundTripAndAnyBytesDecodeOrThrow() throws {
        try FuzzRun("MobileProtocol.terminalInput", seed: 0x51, iterations: 2_000).forEach { rng in
            try Self.terminalInputFrame(&rng)
        }
    }

    @Test func syncFramesDecodeOrThrowForAnyBytes() throws {
        try FuzzRun("MobileProtocol.syncFrames", seed: 0x52, iterations: 2_000).forEach { rng in
            try Self.syncFrames(&rng)
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

    struct RenderGridBaseIsNotAnObject: Error {}

    static func renderGridObject(_ base: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: base) as? [String: Any] else {
            throw RenderGridBaseIsNotAnObject()
        }
        return object
    }

    /// One or two fields of `object` set to an extreme value, so most frames still decode and reach
    /// the replay. Returns how many of the frame and its byte mutation decoded.
    static func renderGridFrame(object: [String: Any], _ rng: inout FuzzRNG) -> Int {
        let extremes: [Any] = [Int.max, Int.min, -1, 0, 1, 4_097, 20_001, 65_536, 1e300, "", "#", "#GGGGGG", NSNull(), [Any](), [String: Any]()]
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
        // Sorted keys: the byte mutation below must see the same bytes in every process.
        guard let data = try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]) else { return 0 }
        var decoded = 0
        for input in [data, mutate(data, &rng)] {
            if let frame = try? MobileTerminalRenderGridFrame.decode(input) {
                decoded += 1
                _ = frame.vtPatchBytes()
                _ = frame.vtReplacementBytes()
            }
        }
        return decoded
    }

    /// A render-grid base frame. The run name carries it: the cases of the parameterized test run
    /// at the same time, and each needs its own artifact files and replay line.
    enum RenderGridBase: String, CaseIterable, Sendable {
        case grid, scrolledDelta

        var data: Data {
            switch self {
            case .grid: MobileProtocolFuzzTests.grid
            case .scrolledDelta: MobileProtocolFuzzTests.scrolledDelta
            }
        }
    }

    @Test(arguments: RenderGridBase.allCases)
    func renderGridFramesFromMutatedJSONDecodeAndReplayOrThrow(_ base: RenderGridBase) throws {
        _ = try MobileTerminalRenderGridFrame.decode(base.data)  // the base itself decodes
        let object = try Self.renderGridObject(base.data)
        var decoded = 0
        try FuzzRun("MobileProtocol.renderGrid.\(base.rawValue)", seed: 0x53, iterations: 3_000).forEach { rng in
            decoded += Self.renderGridFrame(object: object, &rng)
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

    static func attachTicket(_ rng: inout FuzzRNG) {
        let coder = CmxAttachTicketCompactCoder()
        _ = try? coder.decode(random(&rng, 200))
        _ = try? coder.decode(mutate(Data(#"{"v":1,"h":"x","p":1}"#.utf8), &rng))
    }

    @Test func attachTicketsDecodeOrThrowForAnyBytes() throws {
        try FuzzRun("MobileProtocol.attachTicket", seed: 0x54, iterations: 2_000).forEach { rng in
            Self.attachTicket(&rng)
        }
    }

    static let timestampEdges: [UInt64] = [0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max]

    static func timestamp(_ rng: inout FuzzRNG) -> UInt64 {
        rng.below(3) == 0 ? timestampEdges[rng.below(timestampEdges.count)] : rng.next()
    }

    /// One observation of four wire timestamps: a split whose parts add up, or nil.
    static func clockOffset(_ estimator: inout MobileTerminalClockOffsetEstimator, _ rng: inout FuzzRNG) throws {
        let t1 = timestamp(&rng), t4 = timestamp(&rng)
        let receive = timestamp(&rng) / 1_000, dispatch = timestamp(&rng) / 1_000
        guard let split = estimator.observe(
            phoneSendNanos: min(t1, t4), macReceiveMicros: min(receive, dispatch),
            macDispatchMicros: max(receive, dispatch), phoneReceiveNanos: max(t1, t4)
        ) else { return }
        try FuzzRun.check(split.uplinkNanos <= split.roundTripNanos, "uplink \(split.uplinkNanos) > round trip \(split.roundTripNanos)")
        try FuzzRun.check(split.uplinkNanos + split.downlinkNanos == split.roundTripNanos, "the split does not add up to the round trip")
    }

    /// Mac timestamps come from the wire. Any four timestamps give a split or nil;
    /// a round trip past Int64.max used to trap in the uplink clamp.
    @Test func clockOffsetSplitsAnyTimestampsOrRefuses() throws {
        var estimator = MobileTerminalClockOffsetEstimator()
        try FuzzRun("MobileProtocol.clockOffset", seed: 0x55, iterations: 2_000).forEach { rng in
            try Self.clockOffset(&estimator, &rng)
        }
        var fresh = MobileTerminalClockOffsetEstimator()
        let huge = fresh.observe(
            phoneSendNanos: 0, macReceiveMicros: 5, macDispatchMicros: 5, phoneReceiveNanos: .max
        )
        #expect(huge?.roundTripNanos == .max)
    }

    static func deliveryAndAcknowledgement(_ rng: inout FuzzRNG) throws {
        let delivery = MobileTerminalInputDelivery(surfaceID: rng.uuid(), streamID: rng.uuid(), sequence: rng.next())
        try FuzzRun.check(MobileTerminalInputDelivery(decoding: delivery.encoded()) == delivery, "a delivery did not round-trip")
        let status = MobileTerminalInputAcknowledgement.Status(rawValue: UInt8(1 + rng.below(7))) ?? .applied
        let ack = MobileTerminalInputAcknowledgement(
            status: status, streamID: rng.uuid(), sequence: rng.next(), expected: rng.next()
        )
        try FuzzRun.check(MobileTerminalInputAcknowledgement(decoding: ack.encoded()) == ack, "an acknowledgement did not round-trip")
        _ = MobileTerminalInputDelivery(decoding: mutate(delivery.encoded(), &rng))
        _ = MobileTerminalInputAcknowledgement(decoding: mutate(ack.encoded(), &rng))
        _ = MobileTerminalInputDelivery(decoding: random(&rng, 48))
        _ = MobileTerminalInputAcknowledgement(decoding: random(&rng, 48))
    }

    @Test func deliveryIdentitiesAndAcknowledgementsRoundTripAndAnyBytesDecodeOrRefuse() throws {
        try FuzzRun("MobileProtocol.delivery", seed: 0x56, iterations: 2_000).forEach { rng in
            try Self.deliveryAndAcknowledgement(&rng)
        }
    }

    /// Whole frames get a marker each; a malformed tail is forwarded unchanged.
    static func laneScoping(_ rng: inout FuzzRNG) throws {
        let scope = MobileEventLaneScope()
        let surface = rng.uuid()
        let marker = scope.marker(surfaceID: surface)
        var block = Data()
        var frames = 0
        for _ in 0..<rng.below(4) {
            block += try MobileSyncFrameCodec.encodeFrame(random(&rng, 32))
            frames += 1
        }
        let scoped = scope.scoped(block, surfaceID: surface.uuidString)
        try FuzzRun.check(scoped.count == block.count + frames * marker.count, "\(frames) whole frames did not get one marker each")
        let mutated = mutate(block, &rng)
        try FuzzRun.check(scope.scoped(mutated, surfaceID: surface.uuidString).count >= mutated.count, "scoping dropped bytes")
        _ = scope.markerScope(inPayload: random(&rng, 20))
    }

    @Test func laneScopingKeepsEveryByteForAnyBlock() throws {
        try FuzzRun("MobileProtocol.laneScoping", seed: 0x57, iterations: 2_000).forEach { rng in
            try Self.laneScoping(&rng)
        }
    }

    static let addressSeeds = ["[::1]:80", "10.0.0.4:49152", "[fe80::1%en0]:1", "1.2.3.4", "[", "]:", "[]:", ":", "::", "[::1]",
                               "100.64.0.1", "fd7a:115c:a1e0::53", "a:b:c", "300.1.1.1:1", "1.1.1.1:65536", "1.1.1.1:0"]

    /// Address parsers read hosts and ports a user typed or a peer sent.
    static func addressText(_ rng: inout FuzzRNG) {
        let seed = Data(addressSeeds[rng.below(addressSeeds.count)].utf8)
        let text = String(decoding: rng.below(4) == 0 ? random(&rng, 24) : mutate(seed, &rng), as: UTF8.self)
        _ = try? CmxIrohLocalSocketAddress(text)
        var pairing = URLComponents()
        pairing.scheme = "cmux"
        pairing.host = "pair"
        pairing.queryItems = [URLQueryItem(name: "v", value: "2"), URLQueryItem(name: "r", value: text)]
        _ = try? CmxPairingQRCode().decode(pairing)
        _ = CmxLoopbackHost().matches(text)
        _ = CmxTailscalePeerAddress(text)
        _ = try? CmxIrohPathHint(kind: .directAddress, value: text, source: .native, privacyScope: .publicInternet)
    }

    @Test func addressParsersAcceptOrRefuseAnyText() throws {
        try FuzzRun("MobileProtocol.addresses", seed: 0x58, iterations: 3_000).forEach { rng in
            Self.addressText(&rng)
        }
        #expect(try CmxIrohLocalSocketAddress("[fd00::1]:4000").port == 4000)
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("MobileProtocol.oneInput", seed: 0x59, iterations: 512)
        // Choice tapes, one per branch of `oneInput` (the render grid branch once per base).
        let tapes: [[UInt8]] = [[0], [1], [2, 0], [2, 1], [3], [4], [5], [6], [7]]
        try run.forEachInput(run.corpus(seeds: tapes.map { Data($0) }), Self.oneInput)
    }
}
