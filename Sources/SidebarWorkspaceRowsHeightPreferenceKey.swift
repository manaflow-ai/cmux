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
        guard let next = nextValue() else { return }
        guard let current = value else {
            value = next
            return
        }
        value = current.rowsHeight >= next.rowsHeight ? current : next
    }
}
