#if os(iOS)
import SwiftUI

extension EnvironmentValues {
    /// Room a list leaves under its last row for a button that floats over the list's bottom (New
    /// Task, set by the tab that shows it), so the last row can scroll clear of it. 0: none.
    @Entry public var cmuxMobileFloatingBottomRoom: CGFloat = 0
}
#endif
