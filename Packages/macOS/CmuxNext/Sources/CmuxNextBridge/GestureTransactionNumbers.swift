public import CmuxNextLayout
import Foundation

/// The daemon `transaction` numbers of one workspace's layout gestures. A layout transaction is one gesture (a drag's
/// release, a key press, a split's sizing): every value of it goes out under one number, so the daemon keeps one undo
/// entry for all its widths and ratios (`layout_undo_coalesces_every_target_in_one_resize_transaction` in
/// cmux-tui-core) and Undo Layout Change takes the gesture back in one step. (The daemon keeps a dock change apart
/// from resizes, so a dock pin with a width is still two steps.) A transaction keeps its number while any of its
/// commands is in flight: its values go out in one turn and are answered in later ones, so every value of it, whatever
/// other gestures go out between them, takes the same number, and nothing of it is kept once its last command is answered.
public struct GestureTransactionNumbers {
    /// The number the newest layout transaction took; the next one takes the number after it.
    public private(set) var latest = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    private var open: [LayoutTransactionID: (number: UInt64, inFlight: Int)] = [:]

    public init() {}

    /// The daemon number for one more command of `transaction`: the one its commands in flight have, or the next one.
    public mutating func number(for transaction: LayoutTransactionID) -> UInt64 {
        if let entry = open[transaction] {
            open[transaction] = (entry.number, entry.inFlight + 1)
            return entry.number
        }
        latest += 1
        open[transaction] = (latest, 1)
        return latest
    }

    /// A command of `transaction` was answered, or failed.
    public mutating func answered(_ transaction: LayoutTransactionID) {
        guard let entry = open[transaction] else { return }
        open[transaction] = entry.inFlight > 1 ? (entry.number, entry.inFlight - 1) : nil
    }
}
