@testable import CmuxNextActions
import Testing

/// Inspect Element inspects web content only (HTML and React pages, such as
/// the agent chat). Native AppKit/SwiftUI surfaces (tabs, panes, the sidebar,
/// the window background, the tab bar's +) never offer it.
@MainActor
struct InspectElementScopeTests {
    private static let inspector: ActionID = "agentPane.togglePointerInspector"
    /// The menus of web content: the agent chat page.
    private static let webMenus: Set<ActionMenuContext> = [.agentChat]

    @Test func noNativeMenuOffersInspectElement() {
        let catalog = ContextMenuCatalog.shared
        for context in ActionMenuContext.allCases where !Self.webMenus.contains(context) {
            let shown = catalog.referencedIDs(catalog.entries(for: context))
            #expect(!shown.contains(Self.inspector), "\(context) offers Inspect Element")
        }
    }

    @Test func theAgentChatPageStillOffersInspectElement() {
        let catalog = ContextMenuCatalog.shared
        #expect(catalog.referencedIDs(catalog.entries(for: .agentChat)).contains(Self.inspector))
    }

    @Test func theCatalogPlacesInspectElementOnlyInWebMenus() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == Self.inspector })
        let contexts = Set(descriptor.surfacePlan.contextMenus.map(\.context))
        #expect(contexts == Self.webMenus)
    }
}
