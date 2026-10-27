import CmuxNextCompat
import CmuxNextTrace

// The trace ring side of ``Signposter``: how its records encode an interval's begin, end and numbers
// (the layout is in Signposter.swift's doc comment and plans/cmux-next/trace.md).
extension Signposter {
    /// How an interval ended: bits 0-7 of its end record's `arg0`.
    enum EndCode {
        /// Ended normally, or at a committed ``CommitBoundary``.
        static let ended: UInt64 = 0
        /// The ``CommitBoundary`` missed the turn's commit (`commit=missed`).
        static let missed: UInt64 = 1
        /// The work ran a nested run loop that waited for the person (`loop=nested`).
        static let nestedLoop: UInt64 = 2
        /// Committed after asking another process to draw, before it presented (`end=page_activated`).
        static let pageActivated: UInt64 = 3

        /// The code of a ``CommitBoundary`` end.
        static func of(_ outcome: CommitBoundary.Outcome) -> UInt64 {
            switch outcome {
            case .committed: ended
            case .missed: missed
            }
        }
    }

    /// The top 24 bits of a begin record's `arg0` for an input age: the age in whole microseconds, saturated
    /// at `0xFF_FFFE` (16.7 s), or all ones for a begin with no input event (a negative or NaN age).
    static func inputAgeBits(milliseconds: Double) -> UInt64 {
        let none: UInt64 = 0xFF_FFFF
        guard milliseconds >= 0 else { return none << 40 }
        let micros = milliseconds * 1_000
        return (micros < Double(none - 1) ? UInt64(micros) : none - 1) << 40
    }

    /// Writes the begin record when `name`'s category is on; returns the slice the end must close, or nil when
    /// the write recorded nothing. The category is read once, by the write itself. `arg1` goes in a thread
    /// slice's begin; an async slice's `arg1` is its id.
    func traceBegin(_ name: SignpostName, id: OSSignpostID, beginNanos: UInt64, arg0: UInt64,
                    arg1: UInt64 = 0) -> SignpostInterval.Ring? {
        if name.opensThreadSlice {
            return trace.begin(name, arg0: arg0, arg1: arg1) ? .thread : nil
        }
        let asyncID = Self.asyncID(id, beginNanos: beginNanos)
        return trace.asyncBegin(name, id: asyncID, arg0: arg0) ? .async(id: asyncID) : nil
    }

    /// Writes the end record of a begin that wrote one, whatever the category flags are now: a recorded begin
    /// always gets its end, and an unrecorded one never does. Only a thread slice's end has `arg1` free (an async
    /// slice's `arg1` is its id).
    func closeInterval(_ name: SignpostName, _ interval: SignpostInterval, arg0: UInt64, arg1: UInt64 = 0) {
        closeRing(name, interval.ring, arg0: arg0, arg1: arg1)
    }

    /// ``closeInterval(_:_:arg0:arg1:)`` for the slice `ring` a begin returned (the plain-value intervals).
    func closeRing(_ name: SignpostName, _ ring: SignpostInterval.Ring?, arg0: UInt64, arg1: UInt64 = 0) {
        switch ring {
        case nil: return
        case .thread: trace.endRecorded(name, arg0: arg0, arg1: arg1)
        case .async(let id):
            assert(arg1 == 0, "\(name) is an async slice: its arg1 is the async id")
            trace.asyncEndRecorded(name, id: id, arg0: arg0)
        }
    }

    /// A scheduled main task's numbers in `arg0` (`stall.main_task` begin, `stall.over_budget`): `ownerID` in
    /// bits 0-31 and the class's code in bits 32-39.
    static func taskArg0(classCode: UInt64, ownerID: UInt32) -> UInt64 {
        UInt64(ownerID) | classCode << 32
    }

    /// The async id of an interval: its `OSSignpostID`, or its begin time when the log system handed out no
    /// id (a logging profile turned the subsystem off, so `makeSignpostID` returns `.null` or `.invalid`).
    static func asyncID(_ id: OSSignpostID, beginNanos: UInt64) -> UInt64 {
        id.rawValue == OSSignpostID.null.rawValue || id.rawValue == OSSignpostID.invalid.rawValue ? beginNanos : id.rawValue
    }

    /// A code byte for the item at `position` of a fixed list (an entrypoint, a work class): `position + 1`, so
    /// 0 stays "not given", saturated at 255 so it never spills into the next field.
    static func code(position: UInt8) -> UInt64 {
        UInt64(position == .max ? .max : position + 1)
    }
}

extension SignpostName {
    /// Whether a ``Signposter`` interval of this name is a thread slice (B/E) in the trace ring: it always begins
    /// and ends inside one synchronous call on one thread, so it nests in that thread's slices. These are the
    /// emitters' synchronous spans and the names whose catalog entry says "Ring: B/E". A name that ends at a
    /// ``CommitBoundary`` (`action.commit`, `key.frame`, `scroll.frame`, `switch.app_activation`) ends after its
    /// turn's slices closed, so it is never one. Every other name is an async slice (AB/AE), which decodes right
    /// wherever its end lands, so a new name defaults to that.
    var opensThreadSlice: Bool {
        switch self {
        case .actionPerform, .stallMainTask, .motionFrame, .motionDragFrame, .keyOmnibarSuggest, .keyPaletteSearch,
             .cefPump, .cefGeometry, .stallCreateSurface, .stallPaletteOpen, .stallIconPickerOpen, .taskRun, .ghosttyRender,
             .launchStartupTask, .cefMemoryPressureVote:
            true
        default:
            false
        }
    }
}

extension ScrollFramePhase {
    /// The phase's number in a ``SignpostName/scrollToFrame`` begin record (bits 0-7 of `arg0`). Fixed: rings
    /// written by an older build decode with the same numbers.
    var traceCode: UInt64 {
        switch self {
        case .touch: 1
        case .began: 2
        case .changed: 3
        case .ended: 4
        case .momentum: 5
        case .wheel: 6
        }
    }
}

extension KeyFrameSignpost.Target {
    /// The target's number in a ``SignpostName/keyToFrame`` begin record (bits 0-7 of `arg0`). Fixed and nonzero.
    var traceCode: UInt64 {
        switch self {
        case .view: 1
        case .terminal: 2
        }
    }
}

extension ScrollFrameTarget {
    /// The target's number in a ``SignpostName/scrollToFrame`` end record (bits 8-15 of `arg0`). Fixed.
    var traceCode: UInt64 {
        switch self {
        case .layout: 1
        case .content: 2
        }
    }
}
