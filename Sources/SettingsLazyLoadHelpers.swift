import SwiftUI

enum SettingsScrollCoordinateSpace {
    static let name = "SettingsScrollCoordinateSpace"
}

enum SettingsLazyLoadTrigger: CaseIterable, Hashable {
    case browserHistory
    case browserImport
}

struct SettingsLazyLoadFramePreferenceKey: PreferenceKey {
    static var defaultValue: [SettingsLazyLoadTrigger: CGRect] = [:]

    static func reduce(
        value: inout [SettingsLazyLoadTrigger: CGRect],
        nextValue: () -> [SettingsLazyLoadTrigger: CGRect]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

struct SettingsLazyLoadMarker: View {
    let trigger: SettingsLazyLoadTrigger

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SettingsLazyLoadFramePreferenceKey.self,
                value: [trigger: proxy.frame(in: .named(SettingsScrollCoordinateSpace.name))]
            )
        }
    }
}

extension View {
    func settingsLazyLoadTrigger(_ trigger: SettingsLazyLoadTrigger) -> some View {
        background(SettingsLazyLoadMarker(trigger: trigger))
    }
}
