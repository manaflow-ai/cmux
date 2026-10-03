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

/// Everything Settings search indexes, in page order: the schema rows,
/// cards and the action buttons `registry` knows.
public struct SettingsSearchIndex {
    public let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Every entry: per section, the schema rows, then the cards, then the
    /// action buttons the registry knows.
    public func entries() -> [SettingsSearchEntry] {
        SettingsSection.allCases.flatMap { entries(in: $0) }
    }

    public func entries(in section: SettingsSection) -> [SettingsSearchEntry] {
        let rows = SettingsSchema.settings(in: section).map { SettingsSearchEntry(setting: $0) }
        let cards = SettingsCardID.allCases.filter { $0.section == section }.map { SettingsSearchEntry(card: $0) }
        let actions = SettingsSchema.actions(in: section).compactMap { id in
            registry.descriptor(for: id).map { SettingsSearchEntry(action: $0, in: section) }
        }
        return rows + cards + actions
    }
}

extension [SettingsSearchEntry] {
    /// The entries whose text holds every word, in their order.
    public func matching(_ words: [String]) -> [SettingsSearchEntry] {
        guard !words.isEmpty else { return [] }
        return filter { entry in words.allSatisfy { entry.haystack.localizedStandardContains($0) } }
    }

    /// The entry Return opens: a title that starts with the query, then a
    /// title holding every word, then the rest, each in page order.
    public func best(_ words: [String]) -> SettingsSearchEntry? {
        let matches = matching(words)
        let phrase = words.joined(separator: " ")
        func rank(_ entry: SettingsSearchEntry) -> Int {
            if entry.title.range(of: phrase, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { return 0 }
            return words.allSatisfy { entry.title.localizedStandardContains($0) } ? 1 : 2
        }
        return matches.enumerated().min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?.element
    }
}

extension SettingsAnchor {
    /// The anchor `key` names (the deep link `openSettings setting:`): a
    /// cmux.json key path (`tabs.newTabKind`), a card (`theme` or
    /// `card.theme`), a section header (`section.keyboard`), or an action
    /// button (`importFromBrowser`, or its anchor id). Nil when Settings
    /// shows no such thing.
    public init?(key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let path = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let descriptor = SettingsSchema.descriptor(for: path) {
            self = .setting(descriptor)
            return
        }
        if let card = SettingsCardID.allCases.first(where: { $0.anchorID == key || $0.rawValue == key }) {
            self = .card(card)
            return
        }
        for section in SettingsSection.allCases {
            if key == SettingsAnchor.header(section).id {
                self = .header(section)
                return
            }
            for action in SettingsSchema.actions(in: section)
            where key == action.rawValue || key == SettingsAnchor.action(action, in: section).id {
                self = .action(action, in: section)
                return
            }
        }
        return nil
    }
}

extension SettingsSearchEntry {
    init(setting descriptor: SettingDescriptor) {
        let text = [descriptor.title, descriptor.help ?? "", descriptor.group, descriptor.section.title, descriptor.id] + descriptor.keywords
        self.init(kind: .setting(descriptor), anchor: .setting(descriptor), title: descriptor.title,
                  haystack: text.joined(separator: " "))
    }

    init(card: SettingsCardID) {
        let text = [card.title, card.section.title] + card.keywords
        self.init(kind: .card(card), anchor: .card(card), title: card.title, haystack: text.joined(separator: " "))
    }

    init(action: ActionDescriptor, in section: SettingsSection) {
        let text = [action.title, action.id.rawValue, section.title] + action.keywords
        self.init(kind: .action(action.id), anchor: .action(action.id, in: section), title: action.title,
                  haystack: text.joined(separator: " "))
    }
}
