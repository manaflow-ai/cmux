import CmuxConversationCore

/// Holds other people's live changes back while the transcript must not
/// change under the reader: while a landed page of older messages is being
/// measured off the main thread, while the finger drags the transcript, and
/// while one of my sends flies into its row.
///
/// A page is measured before it is applied, so the frame that shows it
/// only places its rows. Without the gate an arrival in that window built
/// the transcript from the store (which already holds the page) and applied
/// the page's rows unmeasured inside its own update: one 25.7 ms update
/// instead of a 1 ms arrival and a measured page.
///
/// Messages holds transcript updates while the finger drags: ChatKit's
/// transcript controller holds chat item updates from
/// `scrollViewWillBeginDragging:` to `scrollViewDidEndDragging:willDecelerate:`
/// (`IMChatItemsUpdateHoldReasonScrollViewDragging`, iOS 26.5 runtime), so
/// nothing is inserted, grown or moved under the finger, and the drag's
/// frames carry no transcript update.
///
/// A send's row hides its status while the flight is in the air. A
/// "Delivered" applied mid-flight (85 ms after the send on a fast link; the
/// flight lands about 1 s after it) grew unseen and popped in at full size
/// at the landing, and the previous message lost its status before the new
/// bubble arrived. Held until the landing, it moves as a later delivery
/// does: the new bubble closes over the old status and the new one grows in.
///
/// Held changes are merged into one and applied once nothing holds them
/// (after the measured page, at the lift, at the landing), each with its
/// own motion. Only live changes the store does not mark as mine wait: a
/// send (with its ack or failure) and anything that is not live traffic
/// are applied at once; the caller then releases what the gate held first,
/// so changes keep their order. The store marks some changes I make like
/// other people's (an edit, Undo Send, Delete for me, a translation); they
/// wait too, at most a flight's second after a send.
public struct ConversationLiveChangeGate: Sendable, Equatable {
    /// Whether a page is being measured.
    public private(set) var isMeasuring = false
    /// Whether the finger is dragging the transcript.
    public private(set) var isDragging = false
    /// The live changes held meanwhile, merged into one.
    public private(set) var held: ConversationStoreChange?
    /// My send flights in the air (a rapid second send flies beside the first).
    public private(set) var flightsInAir = 0

    /// Whether anything holds other people's changes back.
    public var isHolding: Bool { isMeasuring || isDragging || flightsInAir > 0 }

    public init() {}

    /// A page started measuring.
    public mutating func beginMeasuring() {
        isMeasuring = true
    }

    /// The finger started dragging the transcript.
    public mutating func beginDragging() {
        isDragging = true
    }

    /// One of my sends took off.
    public mutating func beginFlight() {
        flightsInAir += 1
    }

    /// A send flight landed; returns what to apply now, unless another
    /// flight is still in the air, a page measures or the finger drags.
    public mutating func endFlight() -> ConversationStoreChange? {
        guard flightsInAir > 0 else { return nil }
        flightsInAir -= 1
        return isHolding ? nil : release()
    }

    /// Whether `change` waits; if it does, the gate keeps it.
    public mutating func hold(_ change: ConversationStoreChange) -> Bool {
        guard isHolding else { return false }
        switch change {
        case .live(_, sentByMe: false), .typing:
            held = held.map { Self.merged($0, change) } ?? change
            return true
        default:
            return false
        }
    }

    /// The held changes, to apply now (before a change the gate let
    /// through, or once nothing holds them); the gate holds nothing after.
    public mutating func release() -> ConversationStoreChange? {
        defer { held = nil }
        return held
    }

    /// The page finished measuring; returns what to apply after it, unless
    /// the finger still drags or a send is still in the air.
    public mutating func finishMeasuring() -> ConversationStoreChange? {
        isMeasuring = false
        return isHolding ? nil : release()
    }

    /// The finger lifted; returns what to apply now, unless a page still
    /// measures or a send is still in the air.
    public mutating func endDragging() -> ConversationStoreChange? {
        isDragging = false
        return isHolding ? nil : release()
    }

    /// One change standing for `earlier` then `later`, both live traffic.
    public static func merged(_ earlier: ConversationStoreChange, _ later: ConversationStoreChange) -> ConversationStoreChange {
        switch (earlier, later) {
        case let (.live(first, firstMine), .live(second, secondMine)):
            return .live(insertedRowIDs: first + second, sentByMe: firstMine || secondMine)
        case (.live, _):
            return earlier
        default:
            return later
        }
    }
}
