public import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// One thing Settings search finds: a schema row, a custom card or an
/// action button, with the anchor that opening it scrolls to.
public struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case setting(SettingDescriptor)
        case card(SettingsCardID)
        case action(ActionID)
    }

    public let kind: Kind
    public let anchor: SettingsAnchor
    public let title: String
    /// The text every word of the query must appear in.
    let haystack: String

    public var id: String { anchor.id }
    public var section: SettingsSection { anchor.section }

    public var descriptor: SettingDescriptor? {
        if case .setting(let descriptor) = kind { return descriptor }
        return nil
    }
}

/// Search results of one section: its matching rows grouped by heading,
/// then its matching cards and buttons.
public struct SettingsSearchResultSection: Identifiable, Sendable {
    public let section: SettingsSection
    public let groups: [SettingsGroup]
    public let others: [SettingsSearchEntry]
    public var id: String { section.rawValue }
}

/// Everything Settings search indexes, in page order, and the anchor a
/// deep link (`openSettings setting:`) names.
public enum SettingsSearchIndex {
    /// Every entry: per section, the schema rows, then the cards, then the
    /// action buttons the registry knows.
    public static func entries(registry: ActionRegistry) -> [SettingsSearchEntry] {
        SettingsSection.allCases.flatMap { entries(in: $0, registry: registry) }
    }

    public static func entries(in section: SettingsSection, registry: ActionRegistry) -> [SettingsSearchEntry] {
        let rows = SettingsSchema.settings(in: section).map { entry(for: $0) }
        let cards = SettingsCardID.allCases.filter { $0.section == section }.map { entry(for: $0) }
        let actions = SettingsSchema.actions(in: section).compactMap { id in
            registry.descriptor(for: id).map { entry(for: $0, in: section) }
        }
        return rows + cards + actions
    }

    /// The entries whose text holds every word, in their order.
    public static func matching(_ words: [String], in entries: [SettingsSearchEntry]) -> [SettingsSearchEntry] {
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in words.allSatisfy { entry.haystack.localizedStandardContains($0) } }
    }

    /// The anchor `key` names: a cmux.json key path (`tabs.newTabKind`), a
    /// card (`theme` or `card.theme`), a section header (`section.keyboard`),
    /// or an action button (`importFromBrowser`, or its anchor id). Nil when
    /// Settings shows no such thing.
    public static func anchor(for key: String) -> SettingsAnchor? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let path = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let descriptor = SettingsSchema.descriptor(for: path) { return .setting(descriptor) }
        if let card = SettingsCardID.allCases.first(where: { $0.anchorID == key || $0.rawValue == key }) { return .card(card) }
        for section in SettingsSection.allCases {
            if key == SettingsAnchor.header(section).id { return .header(section) }
            for action in SettingsSchema.actions(in: section)
            where key == action.rawValue || key == SettingsAnchor.action(action, in: section).id {
                return .action(action, in: section)
            }
        }
        return nil
    }

    static func entry(for descriptor: SettingDescriptor) -> SettingsSearchEntry {
        let text = [descriptor.title, descriptor.help ?? "", descriptor.group, descriptor.section.title, descriptor.id] + descriptor.keywords
        return SettingsSearchEntry(kind: .setting(descriptor), anchor: .setting(descriptor), title: descriptor.title,
                                   haystack: text.joined(separator: " "))
    }

    static func entry(for card: SettingsCardID) -> SettingsSearchEntry {
        let text = [card.title, card.section.title] + card.keywords
        return SettingsSearchEntry(kind: .card(card), anchor: .card(card), title: card.title, haystack: text.joined(separator: " "))
    }

    static func entry(for action: ActionDescriptor, in section: SettingsSection) -> SettingsSearchEntry {
        let text = [action.title, action.id.rawValue, section.title] + action.keywords
        return SettingsSearchEntry(kind: .action(action.id), anchor: .action(action.id, in: section), title: action.title,
                                   haystack: text.joined(separator: " "))
    }
}
