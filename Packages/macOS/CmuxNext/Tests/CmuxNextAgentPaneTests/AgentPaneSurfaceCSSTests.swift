import CmuxNextAgentPane
import Foundation
import Testing

/// Lawrence R48: the agent pane (chats, the session list and the new tab
/// page) shows the window's one background. The shipped stylesheet gives
/// its layout containers no background of their own: each paints the page
/// color the host sets (`--agent-page-bg`, the surface token in an opaque
/// window and transparent over a see-through one, `AgentPaneTheme`) or
/// nothing. A tint there (the old session-list step) shows a second
/// background (scripts/cmux-next/background-match-e2e.py).
struct AgentPaneSurfaceCSSTests {
    static let containers = ["acpmux-shell", "acpmux-sidebar", "acpmux-rail", "acpmux-main"]

    /// The `background` values of every rule whose selector ends at `name`.
    private static func backgrounds(of name: String, in css: String) throws -> [String] {
        let rule = try Regex("(?:^|[{},])\\s*\\.\(name)\\s*\\{([^}]*)\\}")
        var values: [String] = []
        for match in css.matches(of: rule) {
            let body = String(css[match.range]).split(separator: "{", maxSplits: 1).last.map(String.init) ?? ""
            for declaration in body.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "background" || parts[0] == "background-color" {
                    values.append(parts[1].replacingOccurrences(of: "}", with: ""))
                }
            }
        }
        return values
    }

    @Test func layoutContainersPaintOnlyThePageColor() throws {
        let page = try #require(AgentPaneView.bundledPage, "the bundled agent pane page")
        let html = try String(contentsOf: page, encoding: .utf8)
        let allowed: Set<String> = ["var(--agent-page-bg)", "none", "transparent"]
        for name in Self.containers {
            for value in try Self.backgrounds(of: name, in: html) {
                #expect(allowed.contains(value), ".\(name) paints \(value)")
            }
        }
    }
}
