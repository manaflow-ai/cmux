public import Foundation

/// The localization key and English text behind each action title, read
/// from the module's string catalogs (`*.xcstrings`), so the checked-in
/// export (`plans/cmux-next/action-surfaces.json`) can name them for other
/// clients. A descriptor keeps only its resolved title, so the key is found
/// by convention (`action.<id>`) or, failing that, by a unique English
/// match; an ambiguous or interpolated title has no key.
public nonisolated struct ActionTitleCatalog: Sendable {
    /// One title string: its table (the catalog's file name) and key.
    public struct Entry: Sendable, Hashable {
        public let table: String
        public let key: String
        public let english: String
    }

    private let byKey: [String: Entry]
    private let byTableKey: [String: Entry]
    private let byEnglish: [String: [Entry]]

    /// - Parameter catalogs: Each catalog's table name and its `.xcstrings` JSON.
    public init(catalogs: [(table: String, data: Data)]) throws {
        var byKey: [String: Entry] = [:]
        var byTableKey: [String: Entry] = [:]
        var byEnglish: [String: [Entry]] = [:]
        for catalog in catalogs {
            let file = try JSONDecoder().decode(StringCatalogFile.self, from: catalog.data)
            for (key, string) in file.strings {
                let english = string.localizations?[file.sourceLanguage]?.stringUnit?.value ?? key
                let entry = Entry(table: catalog.table, key: key, english: english)
                if byKey[key] == nil || catalog.table == "Localizable" { byKey[key] = entry }
                byTableKey[catalog.table + "\u{0}" + key] = entry
                byEnglish[english, default: []].append(entry)
            }
        }
        self.byKey = byKey
        self.byTableKey = byTableKey
        self.byEnglish = byEnglish
    }

    /// No catalogs: every title exports without a key.
    public init() {
        byKey = [:]
        byTableKey = [:]
        byEnglish = [:]
    }

    /// The string with `key` in `table`, if the catalogs have it.
    public func entry(key: String, table: String) -> Entry? {
        byTableKey[table + "\u{0}" + key]
    }

    /// The string behind `descriptor`'s title, if one can be named.
    public func entry(for descriptor: ActionDescriptor) -> Entry? {
        if let entry = byKey["action.\(descriptor.id.rawValue)"], entry.english == descriptor.title { return entry }
        let matches = Set(byEnglish[descriptor.title] ?? [])
        let actionKeys = matches.filter { $0.key.hasPrefix("action.") }
        if actionKeys.count == 1 { return actionKeys.first }
        return matches.count == 1 ? matches.first : nil
    }
}

/// The parts of an `.xcstrings` file the title catalog reads.
private nonisolated struct StringCatalogFile: Decodable {
    struct StringEntry: Decodable {
        struct Localization: Decodable {
            struct Unit: Decodable { let value: String? }
            let stringUnit: Unit?
        }
        let localizations: [String: Localization]?
    }
    let sourceLanguage: String
    let strings: [String: StringEntry]
}
