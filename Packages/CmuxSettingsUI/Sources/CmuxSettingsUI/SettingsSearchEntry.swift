import Foundation

public enum SettingsSearchEntryKind: Sendable {
    case section
    case setting
}

public struct SettingsSearchEntry: Identifiable, Sendable {
    public let id: String
    public let kind: SettingsSearchEntryKind
    public let target: SettingsNavigationTarget
    public let title: String
    public let subtitle: String?
    public let symbolName: String
    public let normalizedSearchText: String

    public init(
        id: String,
        kind: SettingsSearchEntryKind,
        target: SettingsNavigationTarget,
        title: String,
        subtitle: String?,
        symbolName: String,
        searchText: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        normalizedSearchText = SettingsSearchIndex.normalized("\(title) \(subtitle ?? "") \(searchText)")
    }
}
