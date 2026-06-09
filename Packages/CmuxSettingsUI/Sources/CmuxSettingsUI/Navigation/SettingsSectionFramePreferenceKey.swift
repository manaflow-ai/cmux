import CoreGraphics
import SwiftUI

struct SettingsSectionFramePreferenceKey: PreferenceKey {
    static let defaultValue: [SettingsSectionID: CGRect] = [:]

    /// Merges section frames reported by every visibility marker.
    ///
    /// - Parameters:
    ///   - value: Current aggregate section frame map.
    ///   - nextValue: Next lazily produced section frame map from SwiftUI.
    static func reduce(
        value: inout [SettingsSectionID: CGRect],
        nextValue: () -> [SettingsSectionID: CGRect]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}
