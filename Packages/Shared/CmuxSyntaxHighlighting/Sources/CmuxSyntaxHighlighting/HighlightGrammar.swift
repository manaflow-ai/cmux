/// A highlight.js language definition that cmux registers on top of the
/// languages bundled with Highlightr.
///
/// Highlightr's bundled highlight.js build only covers highlight.js's own
/// language set. A grammar here fills a gap for a language ``LanguageCatalog``
/// maps to, without replacing Highlightr's bundled script.
struct HighlightGrammar: Sendable {
    /// highlight.js language id, the value ``LanguageCatalog`` returns for the
    /// grammar's file extensions.
    let name: String

    /// JavaScript expression that evaluates to a highlight.js language definer,
    /// `function (hljs) { return { ... }; }`.
    let definitionScript: String
}
