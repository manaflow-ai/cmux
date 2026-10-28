#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import Testing

/// The wire between cmux and the Chromium host app: the same golden frame as
/// ChromiumHost/tests/chromium_host_wire_test.cpp (scripts/cmux-next/tests/chromium-host-wire.test.sh).
@Suite struct ChromiumHostFrameTests {
    static let golden: [UInt8] = hexBytes(
        "05000000030000000a000000feffffffffffff7f0300000004000000ffffffff"
            + "00001000000000000807060504030201010000000000000061004100efbeadde")

    static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    static var goldenFrame: ChromiumHostFrame {
        var frame = ChromiumHostFrame(.key, v: [10, -2, Int32.max, 3, 4, -1], flags: 0x100000, t0: 0x0102030405060708,
                                      payload: Array("abc".utf8))
        frame.t1 = 1
        frame.ch = 0x61
        frame.unmod = 0x41
        frame.seq = 0xdeadbeef
        return frame
    }

    @Test func encodesTheGoldenFrame() {
        #expect(Self.goldenFrame.encoded() == Self.golden + Array("abc".utf8))
    }

    @Test func decodesTheGoldenFrame() throws {
        let bytes = Self.golden + Array("abc".utf8) + [9, 9]
        guard case .frame(let frame, let consumed) = ChromiumHostFrame.decode(bytes[...]) else {
            Issue.record("no frame")
            return
        }
        #expect(consumed == 67)
        #expect(frame == Self.goldenFrame)
        #expect(frame.kind == .key)
        #expect(frame.text == "abc")
    }

    /// Task 092: the control seq rides in t1's high 32 bits and keeps the
    /// page in its low 32 bits, as `SetCtlSeq` in chromium_host_wire.h
    /// (chromium_host_order_test.cpp checks the same bits).
    @Test func carriesTheControlSeqInT1HighBits() {
        var frame = ChromiumHostFrame(.key)
        frame.t1 = 0x1234
        frame.ctlSeq = 0xabcd_ef01
        #expect(frame.t1 == 0xabcd_ef01_0000_1234)
        #expect(frame.ctlSeq == 0xabcd_ef01)
        let bytes = frame.encoded()
        #expect(Array(bytes[48..<56]) == [0x34, 0x12, 0, 0, 0x01, 0xef, 0xcd, 0xab])
        frame.ctlSeq = 0
        #expect(frame.t1 == 0x1234)
    }

    @Test func waitsForTheRestOfAFrame() {
        let bytes = Self.golden + Array("ab".utf8)
        #expect(ChromiumHostFrame.decode(bytes[...]) == .needMore)
        #expect(ChromiumHostFrame.decode(Self.golden[0..<63]) == .needMore)
    }

    @Test func refusesAPayloadOverTheLimit() {
        var bytes = Self.golden
        let length = UInt32(ChromiumHostFrame.maxPayload + 1)
        for index in 0..<4 { bytes[4 + index] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(index))) }
        #expect(ChromiumHostFrame.decode(bytes[...]) == .invalid)
    }

    @Test func keepsAnUnknownKind() {
        let frame = ChromiumHostFrame(rawKind: 999)
        guard case .frame(let decoded, _) = ChromiumHostFrame.decode(frame.encoded()[...]) else {
            Issue.record("no frame")
            return
        }
        #expect(decoded.rawKind == 999)
        #expect(decoded.kind == nil)
    }

    // MARK: Wheel

    /// The same bytes as `kWheelGolden` in chromium_host_wire_test.cpp: a
    /// gesture change (precise, shift held) and the momentum's start.
    static let wheelGolden: [[UInt8]] = [
        hexBytes("0400000000000000780000002d0000006affffffd20400000400000000000000"
            + "000002000000008055443322110000000700000000000000000000002a000000"),
        hexBytes("0400000000000000780000002d000000000000000af6ffff0000000001000000"
            + "000000000000008056443322110000000700000000000000000000002b000000"),
    ]

    static let shift: UInt64 = 1 << 17  // NSEvent.ModifierFlags.shift
    static let began: UInt = 1, stationary: UInt = 2, changed: UInt = 4, ended: UInt = 8, cancelled: UInt = 16, mayBegin: UInt = 32

    static var wheelGoldenFrames: [ChromiumHostFrame] {
        let gesture = ChromiumHostFrame.Wheel(x: 120, y: 45, deltaX: -1.5, deltaY: 12.34, precise: true, phase: changed,
                                              momentumPhase: 0, modifierFlags: shift, time: 0x11_2233_4455)
        let momentum = ChromiumHostFrame.Wheel(x: 120, y: 45, deltaX: 0, deltaY: -25.5, precise: true, phase: 0,
                                               momentumPhase: began, modifierFlags: 0, time: 0x11_2233_4456)
        return zip([gesture, momentum], [UInt32(42), 43]).map { wheel, seq in
            var frame = ChromiumHostFrame.wheel(wheel)
            frame.t1 = 7
            frame.seq = seq
            return frame
        }
    }

    /// Before the task a wheel frame carried whole-pixel deltas and nothing
    /// else: the phases, the momentum and the precise flag never reached the host.
    @Test func encodesTheGoldenWheelFrames() {
        #expect(Self.wheelGoldenFrames.map { $0.encoded() } == Self.wheelGolden)
    }

    @Test func decodesTheGoldenWheelFrames() throws {
        let decoded: [ChromiumHostFrame.Wheel] = try Self.wheelGolden.map { bytes in
            guard case .frame(let frame, consumed: 64) = ChromiumHostFrame.decode(bytes[...]) else { throw WheelDecodeError() }
            return try #require(frame.wheelFields)
        }
        #expect(decoded.map(\.phase) == [Self.changed, 0])
        #expect(decoded.map(\.momentumPhase) == [0, Self.began])
        let allPrecise = decoded.allSatisfy(\.precise)
        #expect(allPrecise)
        #expect(decoded.map(\.deltaY) == [12.34, -25.5])
        #expect(decoded[0].deltaX == -1.5)
        #expect(decoded.map(\.modifierFlags) == [Self.shift, 0])
        #expect(decoded.map(\.time) == [0x11_2233_4455, 0x11_2233_4456])
    }

    struct WheelDecodeError: Error {}

    /// A whole trackpad scroll, gesture then momentum, comes back with every
    /// phase it was sent with.
    @Test func roundTripsAMomentumScroll() throws {
        let sent: [(phase: UInt, momentum: UInt)] = [
            (Self.mayBegin, 0), (Self.began, 0), (Self.changed, 0), (Self.stationary, 0), (Self.ended, 0),
            (0, Self.began), (0, Self.changed), (0, Self.ended), (Self.cancelled, 0),
        ]
        for (index, phases) in sent.enumerated() {
            let wheel = ChromiumHostFrame.Wheel(x: Int32(index), y: -3, deltaX: 0.25, deltaY: -Double(index), precise: index % 2 == 0,
                                                phase: phases.phase, momentumPhase: phases.momentum, modifierFlags: Self.shift,
                                                time: UInt64(index))
            guard case .frame(let frame, _) = ChromiumHostFrame.decode(ChromiumHostFrame.wheel(wheel).encoded()[...]) else {
                throw WheelDecodeError()
            }
            #expect(frame.wheelFields == wheel)
        }
    }

    /// Deltas keep hundredths, round to the nearest, and clamp to the field;
    /// a modifier value with bit 63 never reads as precise.
    @Test func wheelDeltasAreFixedPointAndThePreciseBitIsItsOwn() throws {
        func frame(_ dy: Double, precise: Bool = false, flags: UInt64 = 0) -> ChromiumHostFrame {
            .wheel(.init(x: 0, y: 0, deltaX: 0, deltaY: dy, precise: precise, phase: 0, momentumPhase: 0, modifierFlags: flags, time: 0))
        }
        #expect(frame(0.004).v[3] == 0)
        #expect(frame(0.005).v[3] == 1)
        #expect(frame(-1.236).v[3] == -124)
        #expect(frame(1e12).v[3] == .max)
        #expect(frame(-.infinity).v[3] == .min)
        #expect(frame(.nan).v[3] == 0)
        let notPrecise = frame(1, flags: ChromiumHostFrame.wheelPrecise | Self.shift)
        #expect(notPrecise.flags == Self.shift)
        #expect(try #require(notPrecise.wheelFields).precise == false)
        #expect(frame(1, precise: true).flags == ChromiumHostFrame.wheelPrecise)
        #expect(ChromiumHostFrame(.key).wheelFields == nil)
    }

    /// The host's report that an input's frame was presented, the same bytes as
    /// chromium_host_wire_test.cpp's kInputPresentedGolden: event time 0x1122334455, presented at 0x1122a0b0c0, vsync.
    static let inputPresentedGolden = hexBytes("6e00000000000000010000000000000000000000000000000000000000000000"
                                               + "00000000000000005544332211000000c0b0a022110000000000000000000000")

    @Test func encodesAndDecodesTheGoldenInputPresentedFrame() throws {
        let presented = ChromiumHostFrame.InputPresented(eventNanos: 0x11_2233_4455, presentedNanos: 0x11_22a0_b0c0,
                                                         feedbackFlags: 1)
        #expect(ChromiumHostFrame.inputPresented(presented).encoded() == Self.inputPresentedGolden)
        guard case .frame(let frame, let consumed) = ChromiumHostFrame.decode(Self.inputPresentedGolden[...]) else {
            Issue.record("the golden input presented frame does not decode")
            return
        }
        #expect(consumed == ChromiumHostFrame.headerSize)
        #expect(frame.kind == .inputPresented)
        #expect(frame.inputPresentedFields == presented)
        #expect(ChromiumHostFrame(.key).inputPresentedFields == nil)
    }

    /// A host announces in its `ready` (`v[2]` bit 0, `kReadyReportsInputPresented`) that it reports each input's
    /// presentation; an older host's `ready` has 0 there.
    @Test func readyAnnouncesInputPresentedReports() {
        #expect(ChromiumHostFrame(.ready, v: [27, 42, 1]).reportsInputPresented)
        #expect(!ChromiumHostFrame(.ready, v: [27, 42]).reportsInputPresented)
        #expect(!ChromiumHostFrame(.context, v: [0, 0, 1]).reportsInputPresented)
    }
}
#endif
