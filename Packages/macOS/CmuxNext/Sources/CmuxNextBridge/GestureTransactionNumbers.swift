public import CmuxNextLayout
import Foundation

/// The daemon `transaction` numbers of one workspace's layout gestures. A layout transaction is one gesture (a drag's
/// release, a key press, a split's sizing): every value of it goes out under one number, so the daemon keeps one undo
/// entry for all its widths and ratios (`layout_undo_coalesces_every_target_in_one_resize_transaction` in
/// cmux-tui-core) and Undo Layout Change takes the gesture back in one step. (The daemon keeps a dock change apart
/// from resizes, so a dock pin with a width is still two steps.) A gesture's values go out in one turn, but another
/// gesture's can go out between them (a change sent from inside another's intent handler), so each recent transaction
/// keeps its number; the oldest are let go past ``remembered`` (a gesture never sends late).
public struct GestureTransactionNumbers {
    /// How many recent transactions keep their numbers.
    public static let remembered = 32
    /// The number the newest layout transaction took; the next one takes the number after it.
    public private(set) var latest = UInt64(Date().timeIntervalSince1970 * 1000) << 8
    private var numbers: [LayoutTransactionID: UInt64] = [:]
    private var order: [LayoutTransactionID] = []

    public init() {}

    /// The daemon number of `transaction`: the one it took, or the next one.
    public mutating func number(for transaction: LayoutTransactionID) -> UInt64 {
        if let number = numbers[transaction] { return number }
        latest += 1
        numbers[transaction] = latest
        order.append(transaction)
        if order.count > Self.remembered { numbers[order.removeFirst()] = nil }
        return latest
    }
}
