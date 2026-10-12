/// The palette's user aliases and pins in cmux.json (cx-9ce.43):
///
/// ```jsonc
/// "palette": {
///   "aliases": { "vs": "splitRight", "nt": "newTab.default" },
///   "pins": ["newTab.default", "splitRight"]
/// }
/// ```
///
/// An alias is a word that names one command (like a shell alias): typing the whole alias puts
/// that command first. Pinned commands lead the empty palette in this order. A bad entry is
/// dropped.
public nonisolated struct PaletteRankingSetting: Sendable, Hashable {
    public static let aliasesPath = ["palette", "aliases"]
    public static let pinsPath = ["palette", "pins"]

    /// The aliases of each action id, in alias order.
    public var aliases: [String: [String]] = [:]
    /// Pinned action ids, in the user's order, each once.
    public var pins: [String] = []

    /// The setting in `root` (the file's whole JSON).
    public init(_ root: JSONValue) {}
}
