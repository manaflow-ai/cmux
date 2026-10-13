import CmuxConversationCore

/// Holds live changes back while a landed page of older messages is being
/// measured off the main thread.
///
/// A page is measured before it is applied, so the frame that shows it
/// only places its rows. Without the gate an arrival in that window built
/// the transcript from the store (which already holds the page) and applied
/// the page's rows unmeasured inside its own update: one 25.7 ms update
/// instead of a 1 ms arrival and a measured page. Held changes are merged
/// into one and applied right after the measured page, each with its own
/// motion (the page without animation, the arrival with its spring).
///
/// Only changes from other people wait: a change I made (a send, an Undo
/// Send) and anything that is not live traffic are applied at once; the
/// caller then releases what the gate held first, so changes keep their
/// order.
public struct ConversationPageMeasureGate: Sendable, Equatable {
    /// Whether a page is being measured.
    public private(set) var isMeasuring = false
    /// The live changes held while it is, merged into one.
    public private(set) var held: ConversationStoreChange?

    public init() {}

    /// A page started measuring.
    public mutating func beginMeasuring() {
        isMeasuring = true
    }

    /// Whether `change` waits for the page; if it does, the gate keeps it.
    public mutating func hold(_ change: ConversationStoreChange) -> Bool {
        false
    }

    /// The held changes, to apply now (before a change the gate let
    /// through, or after the measured page); the gate holds nothing after.
    public mutating func release() -> ConversationStoreChange? {
        defer { held = nil }
        return held
    }

    /// The page finished measuring; returns what to apply after it.
    public mutating func finishMeasuring() -> ConversationStoreChange? {
        isMeasuring = false
        return release()
    }

    /// One change standing for `earlier` then `later`, both live traffic.
    public static func merged(_ earlier: ConversationStoreChange, _ later: ConversationStoreChange) -> ConversationStoreChange {
        later
    }
}
