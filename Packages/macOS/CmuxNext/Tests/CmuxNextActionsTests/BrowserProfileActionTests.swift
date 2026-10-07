import CmuxNextActions
import Testing

/// Browser profile actions (plans/cmux-next/data-model.md 5 and 7): each is in
/// the palette and the CLI, takes its profile as a `browser-profile` target,
/// and appears in the context menus of the object it acts on.
@Suite struct BrowserProfileActionTests {
    let catalog = Dictionary(uniqueKeysWithValues: ActionCatalog.all.map { ($0.id, $0) })

    static let ids: [ActionID] = [
        "browserProfile.new", "browserProfile.rename", "browserProfile.setColor", "browserProfile.clearColor",
        "browserProfile.setIcon", "browserProfile.clearIcon", "browserProfile.delete",
        "browserProfile.newTab", "browserProfile.newWindow", "browserProfile.newWorkspace", "browserProfile.openLink",
        "browserProfile.setWorkspaceDefault", "browserProfile.clearWorkspaceDefault",
        "browserProfile.setSpaceDefault", "browserProfile.clearSpaceDefault",
        "browserProfile.moveTab", "browserProfile.duplicateTab", "browserProfile.manageExtensions",
    ]

    @Test func everyBrowserProfileActionIsCataloguedWithACLIVerb() throws {
        for id in Self.ids {
            let descriptor = try #require(catalog[id], "\(id)")
            #expect(descriptor.cliName.hasPrefix("browser-profile "), "\(id): \(descriptor.cliName)")
            #expect(descriptor.surfaces.contains(.palette), "\(id)")
            #expect(descriptor.surfaces.contains(.keyboard), "\(id) must take a shortcut")
        }
    }

    @Test func profileArgumentsAreBrowserProfileTargets() throws {
        let unscoped: Set<ActionID> = ["browserProfile.new", "browserProfile.clearWorkspaceDefault", "browserProfile.clearSpaceDefault"]
        for id in Self.ids where !unscoped.contains(id) {
            let descriptor = try #require(catalog[id])
            let takesProfile = descriptor.arguments.contains { $0.kind == .target(.browserProfile) }
                || descriptor.targets.contains(.browserProfile)
            #expect(takesProfile, "\(id)")
        }
        #expect(ActionTargetRef(parsing: "browser-profile:default") == ActionTargetRef(kind: .browserProfile, id: "default"))
    }

    @Test func deleteIsDestructive() throws {
        #expect(try #require(catalog["browserProfile.delete"]).isDestructive)
    }

    @Test func contextMenusOfferTheProfileActionsOfTheirObject() {
        func ids(_ context: ActionMenuContext) -> Set<ActionID> {
            Set(ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: context)))
        }
        #expect(ids(.tab).isSuperset(of: ["browserProfile.moveTab", "browserProfile.duplicateTab"]))
        #expect(ids(.newTab).contains("browserProfile.newTab"))
        #expect(ids(.workspaceRow).isSuperset(of: ["browserProfile.setWorkspaceDefault", "browserProfile.clearWorkspaceDefault"]))
        #expect(ids(.profile).isSuperset(of: ["browserProfile.setSpaceDefault", "browserProfile.clearSpaceDefault"]))
        #expect(ids(.browserProfile).isSuperset(of: ["browserProfile.newTab", "browserProfile.rename", "browserProfile.delete",
                                                     "browserProfile.manageExtensions"]))
    }

    @Test func theOldProfileStubsAliasTheNewActions() {
        #expect(ActionCatalog.legacyAliases["browserNewProfile"] == "browserProfile.new")
        #expect(ActionCatalog.legacyAliases["browserRenameProfile"] == "browserProfile.rename")
    }
}

@MainActor @Suite struct BrowserProfileTargetArgumentTests {
    @Test func aBrowserProfileTargetSuppliesTheProfileArgument() {
        let registry = ActionRegistry.standard()
        var collected: [ActionID] = []
        var ran: [ActionInvocation] = []
        registry.argumentCollector = { id, _ in collected.append(id) }
        registry.bind("browserProfile.newWindow", invoke: { ran.append($0) })
        registry.bind("workspace.mergeInto", invoke: { ran.append($0) })
        registry.perform("browserProfile.newWindow", invocation: ActionInvocation(target: ActionTargetRef(kind: .browserProfile, id: "default")))
        #expect(ran.count == 1 && collected.isEmpty)
        // Without a profile target the palette asks for it.
        registry.perform("browserProfile.newWindow", invocation: ActionInvocation())
        #expect(collected == ["browserProfile.newWindow"])
        // An action that acts on the target's kind still asks for its argument.
        registry.perform("workspace.mergeInto", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: "w1")))
        #expect(collected == ["browserProfile.newWindow", "workspace.mergeInto"])
    }
}
