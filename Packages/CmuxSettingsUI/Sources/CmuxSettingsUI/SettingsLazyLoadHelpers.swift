import SwiftUI

public enum SettingsScrollCoordinateSpace {
    public static let name = "SettingsScrollCoordinateSpace"
}

public enum SettingsLazyLoadTrigger: CaseIterable, Hashable, Sendable {
    case browserHistory
    case browserImport
}

public struct SettingsLazyLoadFramePreferenceKey: PreferenceKey {
    public static var defaultValue: [SettingsLazyLoadTrigger: CGRect] = [:]

    public static func reduce(
        value: inout [SettingsLazyLoadTrigger: CGRect],
        nextValue: () -> [SettingsLazyLoadTrigger: CGRect]
    ) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

public struct SettingsLazyLoadMarker: View {
    public let trigger: SettingsLazyLoadTrigger

    public init(trigger: SettingsLazyLoadTrigger) {
        self.trigger = trigger
    }

    public var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SettingsLazyLoadFramePreferenceKey.self,
                value: [trigger: proxy.frame(in: .named(SettingsScrollCoordinateSpace.name))]
            )
        }
    }
}

public extension View {
    func settingsLazyLoadTrigger(_ trigger: SettingsLazyLoadTrigger) -> some View {
        background(SettingsLazyLoadMarker(trigger: trigger))
    }
}
