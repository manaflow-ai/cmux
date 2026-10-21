import Foundation

/// Gives each extension row of Chromium's page menu its extension's icon,
/// as Chrome draws it. CEF's menu model drops the icons and says nothing
/// about which extension added a row, so this tells them apart from what
/// the model keeps.
///
/// Chromium (`ContextMenuMatcher::AppendExtensionItems`) gives every
/// extension one top-level row with a command id from
/// ``commandRange``: its only item, or a submenu titled with the extension's
/// name that holds all its items when it has more than one (or one that is
/// a checkbox or radio item). Only that top-level row has the icon.
///
/// Matching, strongest first: a row titled exactly with an extension's
/// name (Chromium's own grouping title) or `short_name`; a title that starts
/// the name or that the name starts ("1Password" and "1Password – Password
/// Manager"); the name's first word in the title. Only extensions that may
/// add page rows (``BrowserExtensionMenuSource/mayAddMenuItems``) take part.
/// One row and one extension left over belong together. A row still
/// unmatched gets Chrome's default extension icon.
///
/// ```swift
/// let icons = BrowserExtensionMenuIcons(sources: [
///     BrowserExtensionMenuSource(id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", name: "1Password – Password Manager",
///                                icon1x: "/…/icons/16.png", icon2x: "/…/icons/32.png"),
/// ])
/// let menu = icons.annotate(BrowserContextMenuItem.decodeList(json))
/// ```
public nonisolated struct BrowserExtensionMenuIcons: Sendable {
    /// Chromium's `IDC_EXTENSIONS_CONTEXT_CUSTOM_FIRST` up to its last id
    /// (`chrome_command_ids.h`, `context_menu_matcher.cc`).
    public static let commandRange = 49000...50000

    /// The extensions that may have added rows.
    public var sources: [BrowserExtensionMenuSource]

    public init(sources: [BrowserExtensionMenuSource]) {
        self.sources = sources
    }

    /// True when `items` has at least one extension row (then the host reads
    /// the extension list; otherwise it does no work).
    public static func hasExtensionRows(_ items: [BrowserContextMenuItem]) -> Bool {
        items.contains { $0.kind != .separator && commandRange.contains($0.id) }
    }

    /// Pure: `items` with ``BrowserContextMenuItem/icon`` and
    /// ``BrowserContextMenuItem/extensionID`` set on each top-level extension
    /// row. Children and every other row are unchanged.
    public func annotate(_ items: [BrowserContextMenuItem]) -> [BrowserContextMenuItem] {
        let rows = items.indices.filter { items[$0].kind != .separator && Self.commandRange.contains(items[$0].id) }
        guard !rows.isEmpty else { return items }
        let candidates = sources.filter(\.mayAddMenuItems)
        var pairs: [(score: Int, row: Int, source: Int)] = []
        for row in rows {
            for (index, source) in candidates.enumerated() {
                let score = Self.score(title: items[row].title, source: source)
                if score > 0 { pairs.append((score, row, index)) }
            }
        }
        pairs.sort { ($0.score, -$0.row, -$0.source) > ($1.score, -$1.row, -$1.source) }
        var owner: [Int: Int] = [:]
        var taken: Set<Int> = []
        for pair in pairs where owner[pair.row] == nil && !taken.contains(pair.source) {
            owner[pair.row] = pair.source
            taken.insert(pair.source)
        }
        let freeRows = rows.filter { owner[$0] == nil }
        let freeSources = candidates.indices.filter { !taken.contains($0) }
        if freeRows.count == 1, freeSources.count == 1 { owner[freeRows[0]] = freeSources[0] }
        var result = items
        for row in rows {
            if let source = owner[row].map({ candidates[$0] }) {
                result[row].icon = source.menuIcon
                result[row].extensionID = source.id
            } else {
                result[row].icon = .defaultExtension
            }
        }
        return result
    }

    /// How surely the row titled `title` belongs to `source` (0: not at all).
    static func score(title: String, source: BrowserExtensionMenuSource) -> Int {
        let row = normalized(title)
        guard !row.isEmpty else { return 0 }
        let name = normalized(source.name)
        let short = source.shortName.map(normalized) ?? ""
        if row == name { return 100 }
        if !short.isEmpty, row == short { return 90 }
        if !name.isEmpty, name.hasPrefix(row) || row.hasPrefix(name) { return 70 }
        if !short.isEmpty, short.hasPrefix(row) || row.hasPrefix(short) { return 65 }
        if let word = name.split(separator: " ").first, word.count >= 3,
           row.split(separator: " ").contains(where: { $0 == word }) { return 50 }
        return 0
    }

    /// Case, accents, `&` mnemonics and runs of spaces do not count.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
