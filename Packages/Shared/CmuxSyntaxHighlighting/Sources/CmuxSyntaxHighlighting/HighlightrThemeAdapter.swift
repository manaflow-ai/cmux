import Foundation
@preconcurrency import Highlightr
import JavaScriptCore

/// Bridges the bundled Highlightr runtime to the syntax-highlighting engine.
final class HighlightrThemeAdapter {
    private let highlightr: Highlightr
    /// Names of requested grammars that failed to register.
    private let unavailableLanguages: Set<String>

    /// Creates an adapter when Highlightr can initialize its JavaScript engine.
    ///
    /// - Parameter grammars: Languages to register on top of Highlightr's
    ///   bundled highlight.js. Defaults to every grammar cmux ships.
    init?(grammars: [HighlightGrammar] = [.hcl]) {
        guard let highlightr = Highlightr() else { return nil }
        // File Preview handles source files that embed another language (for
        // example dbt SQL with Jinja delimiters). Keep valid tokens around
        // grammar-illegal characters instead of aborting the whole document.
        highlightr.ignoreIllegals = true
        self.highlightr = highlightr
        let hljs = Self.highlightJS(in: highlightr)
        unavailableLanguages = Set(
            grammars.filter { !Self.register($0, in: hljs) }.map(\.name)
        )
    }

    func setTheme(to name: String) -> Bool {
        highlightr.setTheme(to: name)
    }

    func highlight(_ text: String, as language: String?) -> NSAttributedString? {
        // Highlightr retries an unknown language id with highlightAuto, which
        // would paint a file whose grammar failed to register as some guessed
        // language. Leave it uncolored instead.
        if let language, unavailableLanguages.contains(language) {
            return nil
        }
        return highlightr.highlight(text, as: language)
    }

    /// Highlightr's `hljs` object, which 2.3.0 keeps private with no hook to
    /// register a language. Package.swift pins Highlightr to that exact
    /// version, and the HCL engine tests fail if an upgrade renames it.
    private static func highlightJS(in highlightr: Highlightr) -> JSValue? {
        Mirror(reflecting: highlightr).children
            .first { $0.label == "hljs" }?
            .value as? JSValue
    }

    /// Registers `grammar` with highlight.js and reports whether highlight.js
    /// now resolves its name.
    private static func register(_ grammar: HighlightGrammar, in hljs: JSValue?) -> Bool {
        guard let hljs, let context = hljs.context else { return false }
        defer { context.exception = nil }
        guard let definer = context.evaluateScript(grammar.definitionScript),
              definer.isObject else {
            return false
        }
        hljs.invokeMethod("registerLanguage", withArguments: [grammar.name, definer])
        let registered = hljs.invokeMethod("getLanguage", withArguments: [grammar.name])
        return registered.map { !$0.isUndefined && !$0.isNull } ?? false
    }
}
