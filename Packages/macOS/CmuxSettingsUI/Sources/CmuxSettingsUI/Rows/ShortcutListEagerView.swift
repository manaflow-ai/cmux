import CmuxSettings
import SwiftUI

/// Eager, full-height inline rendering of the shortcut-recorder rows — the
/// non-virtualized alternative to ``ShortcutListView``. It flows directly in the
/// Settings page scroll with no inner scroll region, matching the upstream layout
/// (the whole list is part of the one continuous page).
///
/// Uses a plain eager `VStack` — deliberately NOT `LazyVStack`. The `LazyVStack`
/// is the original scroll-jump bug: on the app active-state flip it de-realizes
/// off-screen rows and re-estimates them shorter, dipping the page's document
/// height so `NSClipView` re-anchors the scroll and strands it. An eager `VStack`
/// keeps every row realized, so the page height is stable across the flip and the
/// jump cannot occur. The cost is realizing all rows (~166 Carbon-backed
/// recorders) up front at window-open — the tradeoff versus ``ShortcutListView``.
///
/// Reuses ``ShortcutListModel`` (all state/logic) and ``ShortcutListRowView`` (all
/// rendering, including its own `isLast` hairline divider) verbatim, so the two
/// list implementations stay behavior-identical.
@MainActor
struct ShortcutListEagerView: View {
    let model: ShortcutListModel

    var body: some View {
        let actions = ShortcutAction.settingsVisibleActions
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                ShortcutListRowView(model: model, action: action, isLast: index == actions.count - 1)
            }
        }
    }
}
