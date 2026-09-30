import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Testing

/// The screen action family (screens are as customizable as tabs): every
/// catalog action has a handler; creation has no default shortcut and no
/// menu; the old window-local switcher toggle is gone; targets that do not
/// resolve and daemons without the capability are refused with a reason.
@MainActor
struct ScreenActionTests {
    typealias Coverage = ActionBindingCoverageTests

    @Test func everyScreenActionIsBound() {
        let registry = Coverage.boundServices().registry
        let unbound = registry.unboundActionIDs(in: [.screen])
        #expect(unbound.isEmpty, "unbound: \(unbound.map(\.rawValue).sorted())")
        #expect(HandlerCoverage.categories.contains(.screen))
    }

    @Test func creatingAScreenHasNoDefaultShortcutOrMenuItem() throws {
        let registry = Coverage.boundServices().registry
        for id: ActionID in ["screen.new", "screen.newWith"] {
            let descriptor = try #require(registry.descriptor(for: id))
            #expect(descriptor.defaultShortcut == nil, "\(id)")
            #expect(descriptor.mainMenu == nil, "\(id)")
            #expect(descriptor.surfaces == [.palette], "\(id)")
        }
        #expect(registry.descriptor(for: "screen.toggleSwitcher") == nil)
    }

    @Test func aUserBindingReachesScreenNew() throws {
        let registry = Coverage.boundServices().registry
        let binding = try #require(ShortcutBindingFormat.parse(.string("ctrl+alt+s")))
        guard case .stroke(let stroke) = binding else { Issue.record("expected one stroke"); return }
        let shortcut = Shortcut(stroke.key, modifiers: [.control, .option])
        registry.setShortcutOverride(shortcut, for: "screen.new")
        #expect(registry.effectiveShortcut(for: "screen.new") == Shortcut("s", modifiers: [.control, .option]))
        #expect(registry.resolve(shortcut)?.id == "screen.new")
    }

    @Test func screenActionsWithoutAWorkspaceAreRefused() {
        let services = Coverage.boundServices()
        for id in ["screen.new", "screen.next", "screen.rename", "screen.setColor", "screen.togglePin", "screen.moveLeft",
                   "screen.closeOthers", "screenGroup.create"] {
            guard case .refused = Coverage.run(services, id) else {
                Issue.record("\(id) ran without a workspace")
                continue
            }
        }
        let missing = ActionTargetRef(kind: .screen, id: "screen_missing")
        #expect(Coverage.run(services, "screen.close", target: missing) == .refused(RefusalStrings.noScreen("screen_missing")))
    }

    @Test func screenGroupActionsNeedAKnownGroup() {
        let services = Coverage.boundServices()
        let group = ActionTargetRef(kind: .screenGroup, id: "sgrp_missing")
        for id in ["screenGroup.rename", "screenGroup.color.red", "screenGroup.moveLeft", "screenGroup.save", "screenGroup.close"] {
            #expect(Coverage.run(services, id, target: group) == .refused(RefusalStrings.noScreenGroup("sgrp_missing")), "\(id)")
        }
    }

    @Test func screenContextMenusOnlyReferenceScreenActions() {
        let registry = Coverage.boundServices().registry
        for context in [ActionMenuContext.screen, .screenGroup] {
            let ids = ContextMenuCatalog.referencedIDs(ContextMenuCatalog.entries(for: context))
            #expect(!ids.isEmpty)
            for id in ids { #expect(registry.descriptor(for: id) != nil, "\(context): \(id)") }
        }
    }
}
