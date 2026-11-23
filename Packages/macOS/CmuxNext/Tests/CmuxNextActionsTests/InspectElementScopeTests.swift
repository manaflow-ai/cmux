@testable import CmuxNextActions
import Testing

/// Point at Element (ask-5077a4ec48) is on the menus of the things it points at: the agent chat page, and cmux's
/// native tabs, panes, workspace rows and sidebar items. Menus of no single object (the window background, the tab
/// bar's +, the new-tab button) never offer it. Until the app's pinned catalog carries the native placements it is
/// on the chat page's menu alone; either catalog passes.
@MainActor
struct InspectElementScopeTests {
    private static let inspector: ActionID = "agentPane.togglePointerInspector"
    private static let webMenus: Set<ActionMenuContext> = [.agentChat]
    private static let nativeMenus: Set<ActionMenuContext> = [.tab, .pane, .workspaceRow, .sidebarItem]

    private var placed: Set<ActionMenuContext> {
        get throws {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == Self.inspector })
            return Set(descriptor.surfacePlan.contextMenus.map(\.context))
        }
    }

    @Test func theCatalogPlacesPointAtElementOnTheChatPageAndTheNativeObjects() throws {
        let contexts = try placed
        #expect(contexts == Self.webMenus || contexts == Self.webMenus.union(Self.nativeMenus), "\(contexts)")
    }

    @Test func noOtherMenuOffersPointAtElement() throws {
        let catalog = ContextMenuCatalog.shared
        let allowed = Self.webMenus.union(Self.nativeMenus)
        for context in ActionMenuContext.allCases where !allowed.contains(context) {
            #expect(!catalog.referencedIDs(catalog.entries(for: context)).contains(Self.inspector), "\(context) offers Point at Element")
        }
    }

    @Test func eachPlacedMenuShowsPointAtElement() throws {
        let catalog = ContextMenuCatalog.shared
        for context in try placed {
            #expect(catalog.referencedIDs(catalog.entries(for: context)).contains(Self.inspector), "\(context)")
        }
    }
}
