public import CmuxNextLayout
import Foundation

/// The daemon `transaction` numbers of one workspace's layout gestures. A layout transaction is one gesture (a drag's
/// release, a key press, a split's sizing): every value of it goes out under one number, so the daemon keeps one undo
/// entry for all its widths and ratios (`layout_undo_coalesces_every_target_in_one_resize_transaction` in
/// cmux-tui-core) and Undo Layout Change takes the gesture back in one step. (The daemon keeps a dock change apart
/// from resizes, so a dock pin with a width is still two steps.) A gesture sends its values in one turn, one after
/// the other, so the newest transaction is all this needs to remember; a value of an older one (none sends late)
/// would take a new number, a step of its own, as before.
public struct GestureTransactionNumbers {
    /// The number the newest layout transaction took; the next one takes the number after it.
    public private(set) var latest = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    private var latestTransaction: LayoutTransactionID?

    public init() {}

    /// The daemon number of `transaction`: the newest one's again, or the next one.
    public mutating func number(for transaction: LayoutTransactionID) -> UInt64 {
        if transaction != latestTransaction {
            latest += 1
            latestTransaction = transaction
        }
        return latest
    }
}
