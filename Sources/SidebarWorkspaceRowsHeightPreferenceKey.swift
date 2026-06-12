import Foundation
import SwiftUI

/// Carries the single whole-content `SidebarWorkspaceRowsMeasurement` of the
/// sidebar workspace rows up to the scroll container, which uses it to size
/// the empty drop/tap area to the remaining viewport (#3241).
struct SidebarWorkspaceRowsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: SidebarWorkspaceRowsMeasurement<UUID>? = nil

    static func reduce(
        value: inout SidebarWorkspaceRowsMeasurement<UUID>?,
        nextValue: () -> SidebarWorkspaceRowsMeasurement<UUID>?
    ) {
        guard let next = nextValue()?.normalizedForStorage else { return }
        guard let current = value else {
            value = next
            return
        }
        // Within-tolerance same-row measurements are intentionally kept at the
        // first value so equivalent layout passes cannot re-emit preference
        // churn before the @State write gate sees them.
        guard !current.isEquivalent(to: next) else { return }
        value = current.rowsHeight >= next.rowsHeight ? current : next
    }
}
