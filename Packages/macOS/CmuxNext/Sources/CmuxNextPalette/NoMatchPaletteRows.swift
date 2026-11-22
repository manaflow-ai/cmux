import CmuxNextActions
import Foundation

/// What Cmd-Shift-P and Cmd-P offer for a query that matched nothing, instead of "No Results":
/// the words as a new workspace's name, as a command to run, as a web search and as a question
/// for an agent. Each runs the path its other entrypoints take (New Workspace is the `newTab`
/// action with its `name` or `command` argument, the web search `browser.selection.search`; ask goes
/// through the go-to source).
struct NoMatchPaletteRows {
    /// Which rows a page offers, in this order.
    enum Kind: CaseIterable {
        case askAgent, searchWeb, newWorkspace, runCommand
    }

    static var section: PaletteSection {
        PaletteSection(id: "noMatch", title: PaletteStrings.sectionNoMatch, order: -200)
    }

    var kinds: [Kind]

    /// The rows for `query`; empty for a blank query.
    @MainActor
    func items(_ query: String, registry: ActionRegistry, source: (any PaletteGoToSource)?) -> [PaletteItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return kinds.compactMap { kind in item(kind, text, registry: registry, source: source) }
    }

    @MainActor
    private func item(_ kind: Kind, _ text: String, registry: ActionRegistry, source: (any PaletteGoToSource)?) -> PaletteItem? {
        switch kind {
        case .newWorkspace:
            guard registry.isBound("newTab") else { return nil }
            return row("noMatch:newWorkspace", PaletteStrings.noMatchNewWorkspace(text), "plus.rectangle.on.rectangle") {
                registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(text)]))
            }
        case .runCommand:
            guard registry.isBound("newTab") else { return nil }
            return row("noMatch:runCommand", PaletteStrings.noMatchRunCommand(text), "terminal") {
                registry.perform("newTab", invocation: ActionInvocation(arguments: ["command": .string(text)]))
            }
        case .searchWeb:
            guard registry.isBound("browser.selection.search") else { return nil }
            return row("noMatch:searchWeb", PaletteStrings.noMatchSearchWeb(text), "magnifyingglass") {
                registry.perform("browser.selection.search", invocation: ActionInvocation(arguments: ["text": .string(text)]))
            }
        case .askAgent:
            guard let source else { return nil }
            return row("noMatch:askAgent", PaletteStrings.noMatchAskAgent(text), "bubble.left.and.text.bubble.right") { [weak source] in
                source?.askAgent(prompt: text)
            }
        }
    }

    @MainActor
    private func row(_ id: String, _ title: String, _ symbol: String, _ run: @escaping @MainActor () -> Void) -> PaletteItem {
        PaletteItem(id: id, title: title, symbol: symbol, section: Self.section,
                    primary: PaletteCommand(id: "run", title: PaletteStrings.open, symbol: "return", effect: .perform { run() }),
                    frecencyKey: nil)
    }
}
