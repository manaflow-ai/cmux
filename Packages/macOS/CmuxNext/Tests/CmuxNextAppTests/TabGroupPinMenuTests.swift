import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import Testing

/// Pin a tab group (PINNED-ITEMS-END-TO-END P3, Chrome parity): pinning a
/// group saves it. The tab group menu offers Pin Group on a group that is
/// not saved and Unpin Group on a saved one, never both; the palette keeps
/// Save Tab Group and Unsave Tab Group. No window is put on screen.
@MainActor
struct TabGroupPinMenuTests {
    private static func ids(_ entries: [ContextMenuEntry]) -> Set<ActionID> {
        Set(ContextMenuCatalog.shared.referencedIDs(entries))
    }

    @Test func theMenuOffersPinOrUnpinByTheSavedState() {
        let open = Self.ids(TabGroupPinMenu.entries(saved: false))
        #expect(open.contains("tabGroup.save"))
        #expect(!open.contains("tabGroup.unsave"), "a group that is not pinned offers no Unpin Group")
        let saved = Self.ids(TabGroupPinMenu.entries(saved: true))
        #expect(saved.contains("tabGroup.unsave"))
        #expect(!saved.contains("tabGroup.save"), "a pinned group offers no Pin Group")
        #expect(open.subtracting(["tabGroup.save"]) == saved.subtracting(["tabGroup.unsave"]), "the rest of the menu is the same")
    }

    @Test func theMenuReadsPinGroupAndThePaletteKeepsSave() {
        let services = ActionBindingCoverageTests.boundServices()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tabGroup, id: "grp_1"))
        #expect(services.registry.action(for: "tabGroup.save")?.targetTitle?(invocation) == PinStrings.pinGroup)
        #expect(services.registry.action(for: "tabGroup.unsave")?.targetTitle?(invocation) == PinStrings.unpinGroup)
        #expect(services.registry.descriptor(for: "tabGroup.save")?.title != PinStrings.pinGroup, "the palette title stays Save Tab Group")
    }
}
