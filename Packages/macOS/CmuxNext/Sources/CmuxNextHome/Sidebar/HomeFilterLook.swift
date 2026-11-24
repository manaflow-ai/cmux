#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// DEBUG ONLY: how the Home list shows an on Unread filter, the playground variants of the user's
/// 2026-11-03 ask (msg 20156: a click on the filter button left the list empty, with nothing to show a
/// filter was on). `debug.home.sidebar_fixture` `filter_look` (0...4) picks one. ``chip`` ships;
/// every variant keeps the lit toggle (a second click turns it off) and the empty list's
/// No Unread Chats over Show All.
enum HomeFilterLook: Int, CaseIterable, Sendable {
    /// A: "Unread ×" under the search row, as wide as its text (the default).
    case chip
    /// B: only the lit toggle; no chip row.
    case litOnly
    /// C: a full-width banner under the search row, "Unread ×" stretched across the list.
    case banner
    /// D: the search field's placeholder names the filter ("Search Unread"); no chip row.
    case searchPlaceholder
    /// E: the chip centered over the list.
    case centeredChip

    /// The chip row shows under the search row.
    var showsChip: Bool { self == .chip || self == .banner || self == .centeredChip }
}
#endif
