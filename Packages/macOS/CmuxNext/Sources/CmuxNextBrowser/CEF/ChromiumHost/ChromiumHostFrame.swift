#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
/// One frame of the wire between cmux and the Chromium host app (prototype
/// behind the feature `cefHelperHost`; plans/cmux-next/cef-helper-app-DESIGN.md).
///
/// The C++ side is `ChromiumHost/src/chromium_host_wire.h`: a 64-byte
/// little-endian header and `payload` bytes after it. Both sides check the
/// same golden frame (`ChromiumHostFrameTests`, `chromium_host_wire_test.cpp`).
/// Field meanings by kind are listed in the header.
nonisolated struct ChromiumHostFrame: Equatable, Sendable {
    enum Kind: UInt32, Sendable {
        // cmux -> host
        case navigate = 1, geometry = 2, mouse = 3, wheel = 4, key = 5, focus = 6, ping = 7, stats = 8, quit = 9, edit = 10
        case ime = 11, textInputWatch = 12, gesture = 13
        // host -> cmux
        case ready = 101, context = 102, address = 103, title = 104, pong = 105, statsReply = 106, error = 107
        case rendererGone = 108, textInputState = 109, inputPresented = 110
    }

    static let headerSize = 64
    /// Longer payloads end the connection: no kind carries more than a URL.
    static let maxPayload = 64 * 1024
    /// How long a host may take to end after `quit` or EOF before it is
    /// ended by force (`kQuitLimitSeconds` in the header: the host `_exit`s
    /// itself; cmux SIGKILLs it). The same reasoning as the app's own
    /// `QuitDeadline.engineStopLimit`: CEF's 3 s browser close plus
    /// Chromium's 10 s shutdown watchdog, with room for a loaded machine.
    static let quitLimit: Duration = .seconds(15)

    /// The raw kind, so a frame of a kind this side does not know still decodes.
    var rawKind: UInt32
    var v: [Int32] = [0, 0, 0, 0, 0, 0]
    var flags: UInt64 = 0
    var t0: UInt64 = 0
    var t1: UInt64 = 0
    var ch: UInt16 = 0
    var unmod: UInt16 = 0
    var seq: UInt32 = 0
    var payload: [UInt8] = []

    init(_ kind: Kind, v: [Int32] = [], flags: UInt64 = 0, t0: UInt64 = 0, payload: [UInt8] = []) {
        rawKind = kind.rawValue
        for (index, value) in v.prefix(6).enumerated() { self.v[index] = value }
        self.flags = flags
        self.t0 = t0
        self.payload = payload
    }

    init(rawKind: UInt32) { self.rawKind = rawKind }

    var kind: Kind? { Kind(rawValue: rawKind) }

    /// The control seq an input ring frame was written after (task 092,
    /// "One ordered input stream" in the header): the high 32 bits of `t1`
    /// (`CtlSeqOf`/`SetCtlSeq`); the low 32 bits name the page (task 041).
    /// The host dispatches the frame only once that control message is
    /// applied. The ring's writer stamps it, and `seq`, from
    /// `cmux_remote_shim_order_input` in write order.
    var ctlSeq: UInt32 {
        get { UInt32(truncatingIfNeeded: t1 >> 32) }
        set { t1 = (t1 & 0xffff_ffff) | UInt64(newValue) << 32 }
    }
    var text: String { String(decoding: payload, as: UTF8.self) }

    /// A wheel frame's fields (`kWheel` and `Wheel` in the header):
    /// the NSEvent's scroll phase, momentum phase and precise
    /// flag, which Chrome builds its wheel event from
    /// (`content/browser/renderer_host/input/web_input_event_builders_mac.mm`)
    /// so its renderer host latches the gesture and flings the page
    /// (`components/input/mouse_wheel_phase_handler.cc`).
    nonisolated struct Wheel: Equatable, Sendable {
        /// Page view points, top left.
        var x: Int32
        var y: Int32
        /// `scrollingDeltaX/Y`: pixels when precise, lines when not; the wire
        /// keeps hundredths (``wheelDeltaScale``).
        var deltaX: Double
        var deltaY: Double
        /// `hasPreciseScrollingDeltas`.
        var precise: Bool
        /// `NSEvent.Phase` raw values of `phase` and `momentumPhase`.
        var phase: UInt
        var momentumPhase: UInt
        /// `NSEvent.ModifierFlags` raw value.
        var modifierFlags: UInt64
        /// The event time (CLOCK_UPTIME_RAW nanoseconds).
        var time: UInt64
    }

    /// `kWheelDeltaScale`: v2 and v3 of a wheel are its deltas in hundredths.
    static let wheelDeltaScale = 100.0
    /// `kWheelPrecise`: a wheel's flags bit for precise deltas. Modifier flags never use it.
    static let wheelPrecise: UInt64 = 1 << 63

    static func wheel(_ wheel: Wheel) -> ChromiumHostFrame {
        ChromiumHostFrame(
            .wheel,
            v: [wheel.x, wheel.y, fixedPoint(wheel.deltaX), fixedPoint(wheel.deltaY),
                Int32(truncatingIfNeeded: wheel.phase), Int32(truncatingIfNeeded: wheel.momentumPhase)],
            flags: (wheel.modifierFlags & ~wheelPrecise) | (wheel.precise ? wheelPrecise : 0),
            t0: wheel.time)
    }

    /// The fields of a wheel frame; nil for another kind.
    var wheelFields: Wheel? {
        guard kind == .wheel else { return nil }
        return Wheel(x: v[0], y: v[1], deltaX: Double(v[2]) / Self.wheelDeltaScale, deltaY: Double(v[3]) / Self.wheelDeltaScale,
                     precise: flags & Self.wheelPrecise != 0, phase: UInt(UInt32(bitPattern: v[4])),
                     momentumPhase: UInt(UInt32(bitPattern: v[5])), modifierFlags: flags & ~Self.wheelPrecise, time: t0)
    }

    /// `delta` in hundredths, rounded and clamped to the field.
    private static func fixedPoint(_ delta: Double) -> Int32 {
        let scaled = (delta * wheelDeltaScale).rounded()
        guard !scaled.isNaN else { return 0 }
        return Int32(min(max(scaled, Double(Int32.min)), Double(Int32.max)))
    }

    /// An input frame's presentation (`kInputPresented` in the header): the host reports when the
    /// frame that shows an input reached the display, by the input's event time, from the fork's presentation
    /// feedback (`gfx::PresentationFeedback`, ui/gfx/presentation_feedback.h), as viz reports it for the frame that
    /// carried the input's `EventMetrics` (cc/metrics/compositor_frame_reporter.cc).
    nonisolated struct InputPresented: Equatable, Sendable {
        /// The input frame's `t0`: its event time (CLOCK_UPTIME_RAW nanoseconds).
        var eventNanos: UInt64
        /// When the frame that shows it reached the display (CLOCK_UPTIME_RAW nanoseconds).
        var presentedNanos: UInt64
        /// `gfx::PresentationFeedback::Flags`.
        var feedbackFlags: UInt32
    }

    /// `kPresentationFailed`: `gfx::PresentationFeedback::kFailure`, the frame never reached the display.
    static let presentationFailed: UInt32 = 1 << 1
    /// `kReadyReportsInputPresented`, in a `ready` frame's `v[2]`: the host sends an `inputPresented` frame for each
    /// input (its fork has the presentation feedback callback).
    static let readyReportsInputPresented: Int32 = 1 << 0

    /// A `ready` frame whose host reports each input's presentation; false for another kind.
    var reportsInputPresented: Bool {
        kind == .ready && v[2] & Self.readyReportsInputPresented != 0
    }

    static func inputPresented(_ presented: InputPresented) -> ChromiumHostFrame {
        var frame = ChromiumHostFrame(.inputPresented, v: [Int32(bitPattern: presented.feedbackFlags)], t0: presented.eventNanos)
        frame.t1 = presented.presentedNanos
        return frame
    }

    /// The fields of an input presented frame; nil for another kind.
    var inputPresentedFields: InputPresented? {
        guard kind == .inputPresented else { return nil }
        return InputPresented(eventNanos: t0, presentedNanos: t1, feedbackFlags: UInt32(bitPattern: v[0]))
    }

    /// The header and payload as sent.
    func encoded() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.headerSize + payload.count)
        func put<T: FixedWidthInteger>(_ value: T) {
            bytes.appendLittleEndian(value)
        }
        put(rawKind)
        put(UInt32(payload.count))
        for value in v { put(UInt32(bitPattern: value)) }
        put(flags)
        put(t0)
        put(t1)
        put(ch)
        put(unmod)
        put(seq)
        bytes.append(contentsOf: payload)
        return bytes
    }

    enum Decoded: Equatable, Sendable {
        /// A whole frame, and how many bytes of the input it took.
        case frame(ChromiumHostFrame, consumed: Int)
        /// The input ends inside a frame.
        case needMore
        /// The header announces a payload over ``maxPayload``: the stream is broken.
        case invalid
    }

    /// Decodes the first frame of `bytes`.
    static func decode(_ bytes: ArraySlice<UInt8>) -> Decoded {
        guard bytes.count >= headerSize else { return .needMore }
        let base = bytes.startIndex
        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size {
                value |= T(bytes[base + offset + index]) << (8 * index)
            }
            return value
        }
        let length = Int(get(4, UInt32.self))
        guard length <= maxPayload else { return .invalid }
        guard bytes.count >= headerSize + length else { return .needMore }
        var frame = ChromiumHostFrame(rawKind: get(0, UInt32.self))
        frame.v = (0..<6).map { Int32(bitPattern: get(8 + 4 * $0, UInt32.self)) }
        frame.flags = get(32, UInt64.self)
        frame.t0 = get(40, UInt64.self)
        frame.t1 = get(48, UInt64.self)
        frame.ch = get(56, UInt16.self)
        frame.unmod = get(58, UInt16.self)
        frame.seq = get(60, UInt32.self)
        frame.payload = Array(bytes[(base + headerSize)..<(base + headerSize + length)])
        return .frame(frame, consumed: headerSize + length)
    }
}
#endif
