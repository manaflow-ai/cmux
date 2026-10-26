/// A set of trace categories: one bit per category in a process's category word (``TraceRuntime/categoryMask``,
/// the ring header's `categories` u64 at offset 168). The bits are the table in plans/cmux-next/trace.md
/// ("Release trace ring: category bits"), the same as Swift's `SignpostCategory.traceBit` (CmuxNextSignposts)
/// and Rust's `cmux_trace::category`. A bit never changes or moves to another category.
///
/// Chrome registers its categories statically (`base/trace_event/builtin_categories.h`) and reads one enabled
/// flag per category at each trace point (`category_group_enabled`); here the whole process shares one word,
/// so a trace point that is off costs one relaxed load and one branch.
///
/// ```swift
/// runtime.setCategories(.blackBox)   // launch: the black box
/// runtime.isEnabled(.frame)          // false until a recording turns it on
/// ```
public struct TraceCategories: OptionSet, Sendable, Hashable {
    /// The category word.
    public let rawValue: UInt64

    /// A set from a category word.
    @inlinable
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The set holding only the category of bit `bit` (0-63).
    @inlinable
    public init(bit: UInt8) {
        rawValue = 1 << UInt64(bit & 63)
    }

    /// Whether the category of bit `bit` (0-63) is in the set: one AND and one compare.
    @inlinable
    public func contains(bit: UInt8) -> Bool {
        rawValue & (1 << UInt64(bit & 63)) != 0
    }

    /// Bit 0: keyboard, menu, palette and CLI actions.
    public static let action = TraceCategories(bit: 0)
    /// Bit 1: a key press to the frame that shows it.
    public static let key = TraceCategories(bit: 1)
    /// Bit 2: workspace, tab, space and window switches.
    public static let `switch` = TraceCategories(bit: 2)
    /// Bit 3: creating a workspace, pane or tab.
    public static let create = TraceCategories(bit: 3)
    /// Bit 4: Chromium work on the main thread.
    public static let cef = TraceCategories(bit: 4)
    /// Bit 5: launch phases.
    public static let launch = TraceCategories(bit: 5)
    /// Bit 6: the app's requests to the cmux-tui daemon.
    public static let daemon = TraceCategories(bit: 6)
    /// Bit 7: hang watch.
    public static let hang = TraceCategories(bit: 7)
    /// Bit 8: child-process ends and soft invariant reports.
    public static let crash = TraceCategories(bit: 8)
    /// Bit 9: layout motion.
    public static let motion = TraceCategories(bit: 9)
    /// Bit 10: display frames.
    public static let frame = TraceCategories(bit: 10)
    /// Bit 11: main-thread spans the stall bench measures.
    public static let stall = TraceCategories(bit: 11)
    /// Bit 12: work items from their post to their run.
    public static let task = TraceCategories(bit: 12)
    /// Bit 13: burst bench events.
    public static let burst = TraceCategories(bit: 13)
    /// Bit 14: input events other than a key-down.
    public static let input = TraceCategories(bit: 14)
    /// Bit 15: cmux's own web pages' responsiveness.
    public static let webview = TraceCategories(bit: 15)
    /// Bit 16: the remote desktop view.
    public static let remote = TraceCategories(bit: 16)
    /// Bit 17: the app's control socket.
    public static let control = TraceCategories(bit: 17)
    /// Bit 18: Ghostty's renderer threads.
    public static let ghostty = TraceCategories(bit: 18)
    /// Bit 19: live window resize ticks.
    public static let resize = TraceCategories(bit: 19)

    /// What every process's black box records from launch while no recording runs (section 3A of
    /// plans/cmux-next/chrome-parity/p09-observability.md): bits 0-8. Each fires at most once per person action
    /// or per rare event, so the always-on ring holds minutes of them and an idle process writes nothing.
    public static let blackBox: TraceCategories = [.action, .key, .switch, .create, .cef, .launch, .daemon, .hang, .crash]

    /// What a `trace.start` recording turns on besides the black box: the categories that fire per frame, per
    /// job or per event (Rust's `category::RECORDING`).
    public static let recordingAdds: TraceCategories = [
        .motion, .frame, .stall, .task, .burst, .input, .webview, .remote, .control, .ghostty, .resize,
    ]

    /// Every category of the table.
    public static let all: TraceCategories = blackBox.union(recordingAdds)
}

extension TraceRuntime {
    /// The categories that record now.
    @inlinable
    public var categories: TraceCategories {
        TraceCategories(rawValue: categoryMask)
    }

    /// Whether any category of `categories` records now: one relaxed load, one AND and one branch, inlined
    /// at the trace point.
    @inlinable @inline(__always)
    public func isEnabled(_ categories: TraceCategories) -> Bool {
        categoryFlags.load(ordering: .relaxed) & categories.rawValue != 0
    }

    /// Replaces the categories that record (launch defaults, `trace.start`, `trace.stop`, the secure-input gate).
    public func setCategories(_ categories: TraceCategories) {
        setCategoryMask(categories.rawValue)
    }
}
