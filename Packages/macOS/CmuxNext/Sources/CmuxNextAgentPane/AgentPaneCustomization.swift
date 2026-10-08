public import Foundation

/// The user's agent pane customization: the files in the `agent-pane`
/// directory next to `cmux.json` (`~/.config/cmux/agent-pane/`).
///
/// - `theme.css`: a stylesheet applied after the pane's own.
/// - `layout.json`: a JSON object handed to the page's registry `configure`.
/// - `registry.js`: a script that registers renderers with
///   `window.cmuxAcpmuxRegistry`.
///
/// The App watches the files, builds a value off the main actor with
/// ``init(directory:)``, and sets it on every ``AgentPaneView``, which pushes
/// it to the page. Each file is optional; a missing or invalid one is left
/// out without stopping the others.
public nonisolated struct AgentPaneCustomization: Equatable, Sendable {
    /// `theme.css`, nil when missing.
    public var themeCSS: String?
    /// `registry.js`, nil when missing.
    public var registryJS: String?
    /// `layout.json` re-serialized with sorted keys; nil when missing or not
    /// a JSON object.
    public var layoutJSON: String?

    /// The files, by name, in the customization directory.
    public static let fileNames = ["theme.css", "layout.json", "registry.js"]

    /// Makes a customization from file contents.
    ///
    /// - Parameters:
    ///   - themeCSS: The stylesheet.
    ///   - registryJS: The registry script.
    ///   - layoutJSON: The layout; dropped unless it is a JSON object.
    public init(themeCSS: String? = nil, registryJS: String? = nil, layoutJSON: String? = nil) {
        self.themeCSS = themeCSS
        self.registryJS = registryJS
        self.layoutJSON = layoutJSON.flatMap { Self.layoutObject(Data($0.utf8)) }
    }

    /// Reads the files in `directory`. Blocking file IO: call it off the
    /// main actor.
    ///
    /// - Parameter directory: Usually ``directory(configFile:)``.
    public init(directory: URL) {
        self.init(
            themeCSS: Self.text(of: "theme.css", in: directory),
            registryJS: Self.text(of: "registry.js", in: directory),
            layoutJSON: Self.text(of: "layout.json", in: directory)
        )
    }

    /// True when no file is present.
    public var isEmpty: Bool { themeCSS == nil && registryJS == nil && layoutJSON == nil }

    /// The customization directory for a settings file: `agent-pane` next to
    /// it, so `CMUX_NEXT_CONFIG_FILE` moves both.
    ///
    /// - Parameter configFile: The `cmux.json` path.
    /// - Returns: The directory holding ``fileNames``.
    public static func directory(configFile: URL) -> URL {
        configFile.deletingLastPathComponent().appending(path: "agent-pane", directoryHint: .isDirectory)
    }

    /// `registry.js` in its own function scope, nil when there is none. Both hosts evaluate it
    /// (evaluateJavaScript): the page's CSP allows no inline script, so the page cannot run it.
    var registryScript: String? {
        guard let registryJS, !registryJS.isEmpty else { return nil }
        return "(function () {\n\(registryJS)\n})();"
    }

    /// The scripts that apply this customization to the loaded page, each
    /// evaluated on its own so a broken `registry.js` cannot stop the theme:
    /// `registry.js` in its own function scope, so replaying it in the same
    /// page doesn't redeclare its top-level `const`, `let` or `class`, then
    /// `cmuxAcpmuxBridge.applyCustomization({themeCSS, layout})`. A missing
    /// theme sends `""`, which clears the style a deleted `theme.css` left.
    func scripts() -> [String] {
        var scripts: [String] = []
        if let registryScript { scripts.append(registryScript) }
        let theme = (try? JSONEncoder().encode(themeCSS ?? "")).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        scripts.append(#"window.cmuxAcpmuxBridge?.applyCustomization({"themeCSS":\#(theme),"layout":\#(layoutJSON ?? "{}")});"#)
        return scripts
    }

    /// `data` as sorted-key JSON when it holds a JSON object.
    private static func layoutObject(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any],
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(data: normalized, encoding: .utf8)
    }

    /// The UTF-8 text of `name` in `directory`, nil when missing or unreadable.
    private static func text(of name: String, in directory: URL) -> String? {
        // concurrency-allow: init(directory:) is documented as blocking; the App calls it from a @concurrent reader.
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
