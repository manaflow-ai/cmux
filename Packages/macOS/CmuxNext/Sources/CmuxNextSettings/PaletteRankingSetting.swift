import Foundation

/// The palette's user aliases, pins and search memory in cmux.json (cx-9ce.43):
///
/// ```jsonc
/// "palette": {
///   "aliases": { "vs": "splitRight", "nt": "newTab.default" },
///   "pins": ["newTab.default", "splitRight"],
///   "searchHistory": true
/// }
/// ```
///
/// An alias is a word that names one command (like a shell alias): typing the whole alias puts
/// that command first. Pinned commands lead the empty palette in this order. A bad entry is
/// dropped.
public nonisolated struct PaletteRankingSetting: Sendable, Hashable {
    /// The aliases of each action id, in alias order.
    public var aliases: [String: [String]] = [:]
    /// Pinned action ids, in the user's order, each once.
    public var pins = PaletteRankingSetting.pinsDefault
    /// Whether the palette learns from what the person runs (`palette.searchHistory`, default on).
    public var remembersSearches = PaletteRankingSetting.searchHistoryDefault
    /// `experiments.paletteV2` (Settings > Advanced > Experiments): the palette v2 look, `off` by default.
    public var paletteV2 = CmuxConfigSnapshot.paletteV2Default
    /// `experiments.palettePreview`: the palette's detail pane and action pill, off by default.
    public var palettePreview = CmuxConfigSnapshot.palettePreviewDefault

    /// The setting in `root` (the file's whole JSON).
    public init(_ root: JSONValue) {
        for (alias, value) in (root.value(at: Self.aliasesPath)?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            let word = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, let id = value.stringValue, !id.isEmpty else { continue }
            aliases[id, default: []].append(word)
        }
        var seen = Set<String>()
        if case .array(let items) = root.value(at: Self.pinsPath) {
            pins = items.compactMap { $0.stringValue }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        if case .bool(let on) = root.value(at: Self.searchHistoryPath) { remembersSearches = on }
        if let look = root.value(at: CmuxConfigSnapshot.paletteV2Path)?.stringValue,
           CmuxConfigSnapshot.paletteV2Values.contains(look) { paletteV2 = look }
        if case .bool(let on) = root.value(at: CmuxConfigSnapshot.palettePreviewPath) { palettePreview = on }
    }
}
