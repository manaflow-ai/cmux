import SwiftUI

struct SettingsSectionVisibilityMarker: View {
    let section: SettingsSectionID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SettingsSectionFramePreferenceKey.self,
                value: [section: proxy.frame(in: .named(SettingsSectionVisibilityCoordinateSpace.name))]
            )
        }
    }
}

extension View {
    /// Reports this view's frame as the scroll-position marker for a settings section.
    ///
    /// - Parameter section: Section represented by the view.
    /// - Returns: A view that publishes its frame through `SettingsSectionFramePreferenceKey`.
    func settingsSectionVisibility(_ section: SettingsSectionID) -> some View {
        background(SettingsSectionVisibilityMarker(section: section))
    }
}
