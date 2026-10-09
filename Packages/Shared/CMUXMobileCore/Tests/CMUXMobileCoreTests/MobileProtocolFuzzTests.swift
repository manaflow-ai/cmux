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
        #expect(decoded > 300, "the mutations must also produce frames that decode")
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
}
