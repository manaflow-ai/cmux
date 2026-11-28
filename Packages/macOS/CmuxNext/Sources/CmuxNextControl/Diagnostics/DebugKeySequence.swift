#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
public import CmuxNextSettings

/// A `debug.key {"sequence": [...]}` planned (DEBUG builds): each step's key event, its offset from
/// the sequence's start, and the event built for it, stamped with its intended press time.
///
/// Building is separate from posting, so tests check the events with no app; a
/// ``DebugKeySequencePlayer`` plays them. A step is `{"key_code": 30, "down": true, "after_ms": 5}`;
/// `"repeat": true` marks a key-down as a held key's auto-repeat (`NSEvent.isARepeat`). A modifier
/// key is a flags-changed event, and every event carries the modifiers held at that point:
///
/// ```swift
/// let sequence = DebugKeySequence([["key_code": 55, "down": true], ["key_code": 13, "down": true, "after_ms": 10]])
/// let stamp = DebugKeySequence.Stamp(base: probe.timestamp, ticksPerSecond: Double(probe.timestamp) / seconds)
/// let event = sequence?.event(sequence!.steps[1], stamp: stamp, source: nil)  // Cmd-W, 10 ms after the start
/// ```
public struct DebugKeySequence: Sendable, Equatable {
    /// One planned event: what to post and its offset from the sequence's start.
    public struct Step: Sendable, Equatable {
        /// The virtual key code.
        public let keyCode: CGKeyCode
        /// Key down (true) or up.
        public let down: Bool
        /// A modifier key: posted as a flags-changed event.
        public let isModifier: Bool
        /// The modifiers held once this step happened.
        public let flags: CGEventFlags
        /// A held key's auto-repeat (key-downs only).
        public let isRepeat: Bool
        /// When the step happens, from the sequence's start (the sum of the gaps so far).
        public let offset: Duration
    }

    /// The event system's clock for one sequence: the start in its own ticks and its ticks per second.
    ///
    /// `CGEventTimestamp` is documented as nanoseconds, yet it follows the HID clock, whose ticks are
    /// not nanoseconds on every Mac; a fresh event's timestamp and the seconds AppKit reads from it
    /// give both.
    public struct Stamp: Sendable, Equatable {
        /// The sequence's start, in event ticks.
        public let base: CGEventTimestamp
        /// Event ticks per second.
        public let ticksPerSecond: Double

        /// A clock that starts at `base` ticks and runs at `ticksPerSecond`.
        ///
        /// - Parameters:
        ///   - base: The sequence's start, in event ticks.
        ///   - ticksPerSecond: Event ticks per second.
        public init(base: CGEventTimestamp, ticksPerSecond: Double) {
            self.base = base
            self.ticksPerSecond = ticksPerSecond
        }

        /// Nanoseconds in a second: the documented unit of `CGEventTimestamp`.
        private static let nanosecondsPerSecond = 1e9

        /// The clock for a sequence that starts now.
        ///
        /// A fresh probe event with a timestamp gives its own ticks and the seconds AppKit reads from it. A probe
        /// with no timestamp (macOS 27, 2026-10-31: every sequence was refused) gives no unit. The start then comes
        /// from the host's clock in the unit that AppKit reads: `stampedRate` says how many
        /// event ticks AppKit takes for a second (``eventTicksPerSecond(stamping:with:read:)``), and the base is the
        /// host's seconds since boot at that rate. Before this rule the base was the host's mach ticks at the
        /// timebase's rate. On a Mac with macOS 26.7 AppKit read those ticks as nanoseconds, so each event of a
        /// sequence was older than it was by 122/125 of the time since boot.
        ///
        /// - Parameters:
        ///   - probeTimestamp: A fresh probe event's `timestamp`.
        ///   - probeSeconds: The seconds AppKit reads from that probe (`NSEvent.timestamp`), nil without one.
        ///   - hostTicks: `mach_absolute_time()` now.
        ///   - timebaseNumer: `mach_timebase_info` numerator (nanoseconds per tick, times `timebaseDenom`).
        ///   - timebaseDenom: `mach_timebase_info` denominator.
        ///   - stampedRate: The event ticks in a second for a probe stamped with the host's nanoseconds now (its
        ///     argument). Asked only when the probe has no timestamp.
        /// - Returns: The start, or nil when neither clock is usable.
        public static func start(probeTimestamp: CGEventTimestamp, probeSeconds: Double?, hostTicks: UInt64,
                                 timebaseNumer: UInt32, timebaseDenom: UInt32,
                                 stampedRate: (CGEventTimestamp) -> Double) -> Stamp? {
            if probeTimestamp > 0, let probeSeconds, probeSeconds > 0 {
                return Stamp(base: probeTimestamp, ticksPerSecond: Double(probeTimestamp) / probeSeconds)
            }
            guard hostTicks > 0, timebaseNumer > 0, timebaseDenom > 0 else { return nil }
            // The host's nanoseconds since boot: ticks x numer / denom, with no overflow of the product.
            // (`truncatingIfNeeded` from 32 bits to 64 bits keeps each value.)
            let denom = UInt64(truncatingIfNeeded: timebaseDenom)
            let product = hostTicks.multipliedFullWidth(by: UInt64(truncatingIfNeeded: timebaseNumer))
            guard product.high < denom else { return nil }
            let nanoseconds = denom.dividingFullWidth(product).quotient
            guard nanoseconds > 0 else { return nil }
            let rate = stampedRate(nanoseconds)
            guard rate != nanosecondsPerSecond else { return Stamp(base: nanoseconds, ticksPerSecond: rate) }
            guard rate.isFinite, rate > 0,
                  let base = CGEventTimestamp(exactly: (Double(nanoseconds) / nanosecondsPerSecond * rate).rounded()) else { return nil }
            return Stamp(base: base, ticksPerSecond: rate)
        }

        /// The event ticks that AppKit takes for a second, by its own read: stamps `probe` with `ticks` and divides
        /// `ticks` by the seconds that `read` gives for the probe. A read with no usable seconds (none, zero, below
        /// zero, not finite) gives nanoseconds, the documented unit of `CGEventTimestamp`.
        ///
        /// - Parameters:
        ///   - probe: A probe event; its timestamp becomes `ticks`.
        ///   - ticks: The timestamp to stamp the probe with.
        ///   - read: The seconds AppKit reads from an event (`NSEvent(cgEvent:)?.timestamp`), nil without one.
        /// - Returns: Event ticks per second.
        public static func eventTicksPerSecond(stamping probe: CGEvent, with ticks: CGEventTimestamp,
                                               read: (CGEvent) -> Double?) -> Double {
            probe.timestamp = ticks
            guard ticks > 0, let seconds = read(probe), seconds.isFinite, seconds > 0 else { return nanosecondsPerSecond }
            return Double(ticks) / seconds
        }

        /// ``start(probeTimestamp:probeSeconds:hostTicks:timebaseNumer:timebaseDenom:stampedRate:)`` for a fresh
        /// `probe` with this host's mach clock now. A probe with no timestamp is stamped to learn the unit: its
        /// timestamp changes.
        ///
        /// - Parameters:
        ///   - probe: A fresh probe event, nil when the system made none.
        ///   - read: The seconds AppKit reads from an event (`NSEvent(cgEvent:)?.timestamp`), nil without one.
        /// - Returns: The start, or nil when neither clock is usable.
        public static func start(probe: CGEvent?, read: (CGEvent) -> Double?) -> Stamp? {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return start(probeTimestamp: probe?.timestamp ?? 0, probeSeconds: probe.flatMap(read), hostTicks: mach_absolute_time(),
                         timebaseNumer: timebase.numer, timebaseDenom: timebase.denom) { nanoseconds in
                probe.map { eventTicksPerSecond(stamping: $0, with: nanoseconds, read: read) } ?? nanosecondsPerSecond
            }
        }

        /// The event timestamp `offset` after the start.
        ///
        /// - Parameter offset: The time since the sequence's start.
        /// - Returns: The timestamp in event ticks, or nil when it is past what a timestamp holds.
        public func timestamp(at offset: Duration) -> CGEventTimestamp? {
            guard let ticks = CGEventTimestamp(exactly: (seconds(offset) * ticksPerSecond).rounded()) else { return nil }
            let (stamp, overflow) = base.addingReportingOverflow(ticks)
            return overflow ? nil : stamp
        }
    }

    private static let modifierFlags: [CGKeyCode: CGEventFlags] = [
        55: .maskCommand, 54: .maskCommand, 56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl, 58: .maskAlternate, 61: .maskAlternate,
    ]

    /// The planned steps, in order.
    public let steps: [Step]

    /// When the last step lands, from the start (the sum of the gaps).
    public var duration: Duration { steps.last?.offset ?? .zero }

    /// ``duration`` in seconds.
    public var durationSeconds: Double { seconds(duration) }

    /// The plan of `json`'s steps.
    ///
    /// - Parameter json: The `sequence` steps of a `debug.key` request.
    /// - Returns: nil when a step has no `key_code` or `down`, a key code that is not a virtual key
    ///   code, or a negative or non-finite `after_ms`.
    public init?(_ json: [JSONValue]) {
        var flags: CGEventFlags = []
        var offset = Duration.zero
        var planned: [Step] = []
        for step in json {
            guard let code = step["key_code"]?.intValue.flatMap(CGKeyCode.init(exactly:)),
                  let down = step["down"]?.boolValue else { return nil }
            let after = step["after_ms"]?.doubleValue ?? 0
            guard after.isFinite, after >= 0 else { return nil }
            offset += .milliseconds(after)
            let modifier = Self.modifierFlags[code]
            if let modifier { if down { flags.insert(modifier) } else { flags.remove(modifier) } }
            planned.append(Step(keyCode: code, down: down, isModifier: modifier != nil, flags: flags,
                                isRepeat: down && step["repeat"]?.boolValue == true, offset: offset))
        }
        steps = planned
    }

    /// The event of `step`, stamped at its intended press time: as with a hardware key, whose
    /// timestamp is set at HID time, an event that waits behind a busy main thread carries that wait
    /// in its input age.
    ///
    /// - Parameters:
    ///   - step: One of ``steps``.
    ///   - stamp: The sequence's start in the event system's clock.
    ///   - source: The event source (its layout fills in the characters, as for hardware).
    /// - Returns: The event, or nil when the system could not make one or its time is past what a
    ///   timestamp holds.
    public func event(_ step: Step, stamp: Stamp, source: CGEventSource?) -> CGEvent? {
        guard let timestamp = stamp.timestamp(at: step.offset),
              let event = CGEvent(keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.down) else { return nil }
        if step.isModifier { event.type = .flagsChanged }
        event.flags = step.flags
        if step.isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.timestamp = timestamp
        return event
    }
}

/// `duration` in seconds (never negative: the gaps add up from zero).
private func seconds(_ duration: Duration) -> Double {
    let (whole, attoseconds) = duration.components
    return max(0, Double(whole) + Double(attoseconds) / 1e18)
}
#endif
