import Foundation

/// A free-form badge text template with `{placeholder}` substitutions, modeled
/// on iTerm2's badge format.
///
/// The template is arbitrary text the user writes; any `{name}` token whose
/// `name` is a known placeholder is replaced with the matching value from a
/// ``TerminalBadgeContext``. Everything else — including `{` / `}` that do not
/// form a known token — passes through literally, so users can write whatever
/// label they like and mix in identity fields where they want them.
///
/// Supported placeholders:
/// - `{workspace}` — the owning workspace's title.
/// - `{tab}` — the surface/tab title.
/// - `{tabIndex}` — the surface's 1-based position within its pane.
/// - `{workspaceIndex}` — the workspace's 1-based position in the sidebar.
///
/// An unknown value in the context (a `nil` field) substitutes the empty
/// string. An unrecognized token (e.g. `{cwd}`) is left verbatim, including its
/// braces, so a typo is visible rather than silently dropped.
///
/// ```swift
/// let template = TerminalBadgeTemplate(rawValue: "{workspace} · {tab} (#{tabIndex})")
/// let context = TerminalBadgeContext(workspace: "main", tab: "shell", tabIndex: 1)
/// template.render(context: context) // "main · shell (#1)"
/// ```
public struct TerminalBadgeTemplate: Sendable, Equatable {
    /// The default template used when the user has not set one: workspace title,
    /// a middle-dot separator, and the tab title.
    public static let defaultRawValue = "{workspace} · {tab}"

    /// The raw, unrendered template string exactly as the user wrote it.
    public let rawValue: String

    /// Creates a template from raw user text.
    ///
    /// - Parameter rawValue: The template string, e.g. `"{workspace} · {tab}"`.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Substitutes the known placeholders in ``rawValue`` with values from
    /// `context` and returns the rendered badge text.
    ///
    /// Known tokens map to context fields (empty string when the field is
    /// `nil`); unknown tokens and stray braces are preserved verbatim. The scan
    /// is single-pass and allocates one result string.
    ///
    /// - Parameter context: The per-surface substitution values.
    /// - Returns: The rendered badge text.
    public func render(context: TerminalBadgeContext) -> String {
        // Single forward scan: copy literal characters, and whenever a balanced
        // `{name}` whose name is a known placeholder appears, splice in its
        // value. Anything else (including an unbalanced or unknown brace group)
        // is copied through unchanged.
        var result = ""
        result.reserveCapacity(rawValue.count)
        var index = rawValue.startIndex
        let end = rawValue.endIndex
        while index < end {
            let character = rawValue[index]
            guard character == "{" else {
                result.append(character)
                index = rawValue.index(after: index)
                continue
            }
            // Look for a closing brace with only token-name characters between.
            var cursor = rawValue.index(after: index)
            var name = ""
            var closed = false
            while cursor < end {
                let inner = rawValue[cursor]
                if inner == "}" {
                    closed = true
                    break
                }
                // A nested `{` means this is not a simple token; bail out and
                // treat the original `{` as a literal so the inner token still
                // gets its own chance to match.
                if inner == "{" { break }
                name.append(inner)
                cursor = rawValue.index(after: cursor)
            }
            if closed, let value = substitution(for: name, context: context) {
                result.append(value)
                index = rawValue.index(after: cursor)
            } else {
                result.append(character)
                index = rawValue.index(after: index)
            }
        }
        return result
    }

    /// Returns the replacement for a placeholder `name`, or `nil` when `name`
    /// is not a recognized placeholder (so the caller preserves it verbatim).
    private func substitution(for name: String, context: TerminalBadgeContext) -> String? {
        switch name {
        case "workspace": return context.workspace ?? ""
        case "tab": return context.tab ?? ""
        case "tabIndex": return context.tabIndex.map(String.init) ?? ""
        case "workspaceIndex": return context.workspaceIndex.map(String.init) ?? ""
        default: return nil
        }
    }
}
