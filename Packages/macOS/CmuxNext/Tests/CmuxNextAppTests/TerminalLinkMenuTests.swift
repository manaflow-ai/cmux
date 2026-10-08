import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// cx-k9go: a right-click on a web link in a terminal offers the page link
/// rows (old cmux had Open Link and Copy Link there; cmux-next only had
/// Open Link in Browser Profile ▸ with two or more profiles). Each row runs
/// its catalog action with the link as `url` and the terminal's tab as the
/// target.
@MainActor @Suite struct TerminalLinkMenuTests {
    static let tab = ActionTargetRef(kind: .tab, id: "tab_1")

    private func registry(_ ran: @escaping (ActionID, ActionInvocation) -> Void) -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for id in ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .browserLink)) {
            registry.bind(id, invoke: { ran(id, $0) })
        }
        return registry
    }

    @Test func aWebLinkOffersTheLinkRowsWithoutThePageOnlyOnes() throws {
        var ran: [(ActionID, ActionInvocation)] = []
        let owner = registry { ran.append(($0, $1)) }
        defer { withExtendedLifetime(owner) {} }
        let items = TerminalLinkMenu.items(for: URL(string: "https://example.com/a"), target: Self.tab, registry: owner)
        let titles = items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles.contains("Open Link in New Tab"))
        #expect(titles.contains("Copy Link"))
        #expect(!titles.contains("Save Link As…"))
        #expect(!titles.contains("Copy Link Text"))
        #expect(items.last?.isSeparatorItem == true, "a separator before the terminal rows")

        let copy = try #require(items.first { $0.title == "Copy Link" })
        _ = (copy.target as? NSObject)?.perform(copy.action, with: copy)
        #expect(ran.map(\.0) == ["browser.link.copy"])
        #expect(ran.first?.1.target == Self.tab)
        #expect(ran.first?.1["url"]?.stringValue == "https://example.com/a")
    }

    @Test func noLinkOrANonWebLinkAddsNothing() {
        let registry = registry { _, _ in }
        #expect(TerminalLinkMenu.items(for: nil, target: Self.tab, registry: registry).isEmpty)
        #expect(TerminalLinkMenu.items(for: URL(string: "file:///tmp/a.txt"), target: Self.tab, registry: registry).isEmpty)
    }
}
