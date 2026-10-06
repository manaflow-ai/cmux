import AppKit
import CmuxNextActions
import Testing

/// The action contract (plans/cmux-next/REWRITE.md): every action reaches
/// every entrypoint, menus reference real actions, names are unique.
@Suite struct ActionContractTests {
    let catalog = ActionCatalog.all

    @Test func everyActionHasAUniqueNounVerbCLIName() {
        var seen: [String: ActionID] = [:]
        for descriptor in catalog {
            let parts = descriptor.cliName.split(separator: " ")
            #expect(parts.count == 2, "\(descriptor.id): \(descriptor.cliName)")
            #expect(descriptor.cliName == descriptor.cliName.lowercased(), "\(descriptor.id)")
            if let other = seen[descriptor.cliName] {
                Issue.record("cliName \(descriptor.cliName) used by \(other) and \(descriptor.id)")
            }
            seen[descriptor.cliName] = descriptor.id
        }
    }

    /// The palette lists every action except palette-internal navigation
    /// and the ones whose surface plan names another reason (New Browser
    /// Tab on Chromium duplicates the default New Browser Tab row; Go to
    /// Location is a row of the titlebar Back / Forward list; Next / Previous
    /// Item move the selection of the focused list, which the palette
    /// replaces while it is open; the page menu's copy, save and Look Up
    /// rows act on the right-clicked element).
    @Test func everyActionIsInThePaletteUnlessExempt() {
        for descriptor in catalog where !descriptor.isPaletteVisible {
            let reason = descriptor.surfacePlan.palette.exemption
            #expect(reason != nil, "\(descriptor.id) is hidden from the palette without a reason")
            #expect((reason == .paletteInternal) == descriptor.requires.contains(.paletteOpen), "\(descriptor.id)")
        }
        #expect(catalog.filter { !$0.isPaletteVisible }.map(\.id.rawValue).sorted()
            == (["browser.findPrevious", "browser.image.copy", "browser.image.copyAddress", "browser.image.saveAs", "browser.link.copy",
                "browser.link.copyText", "browser.link.saveAs", "browser.selection.copy", "browser.selection.lookUp",
                "commandPaletteNext", "commandPalettePrevious", "history.goTo", "list.next", "list.previous",
                "omnibar.openInBackgroundTab", "omnibar.openInForegroundTab", "openBrowser.chromium"]
            + ["paletteKey.firstItem", "paletteKey.lastItem", "paletteKey.pageUp", "paletteKey.pageDown", "paletteKey.submit",
               "paletteKey.submitAlternate", "paletteKey.openActions", "paletteKey.closeActions", "paletteKey.toggleActions",
               "paletteKey.escape", "paletteKey.enterRow", "paletteKey.leaveLevel", "paletteKey.back",
               "paletteKey.filterDeleteBackward", "paletteKey.closeItem"]).sorted())
    }

    @Test func shortcutIDsAreUniqueAndDefaultsDoNotCollide() {
        let ids = catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ActionRegistry.standard().shortcutConflicts().isEmpty)
    }

    @Test func everyContextMenuIDResolves() {
        let ids = Set(catalog.map(\.id))
        for context in ActionMenuContext.allCases {
            let entries = ContextMenuCatalog.shared.entries(for: context)
            #expect(!entries.isEmpty, "\(context) menu is empty")
            for id in ContextMenuCatalog.shared.referencedIDs(entries) {
                #expect(ids.contains(id), "\(context) menu references unknown \(id)")
            }
        }
    }

    @Test func argumentSchemasAreWellFormed() {
        for descriptor in catalog {
            let names = descriptor.arguments.map(\.name)
            #expect(Set(names).count == names.count, "\(descriptor.id)")
            for argument in descriptor.arguments {
                #expect(!argument.title.isEmpty, "\(descriptor.id).\(argument.name)")
                if case .enumeration(let cases) = argument.kind {
                    #expect(!cases.isEmpty, "\(descriptor.id).\(argument.name)")
                }
            }
        }
    }

    @Test func groupFamiliesAreComplete() {
        let ids = Set(catalog.map(\.id.rawValue))
        let colors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]
        let tabGroup = ["create", "addTab", "removeTab", "rename", "setColor", "toggleCollapsed", "collapse", "expand",
                        "newTab", "ungroup", "close", "moveToNewWindow", "moveToNewSplit", "moveToNewColumn",
                        "moveToNewWorkspace", "moveToWorkspace", "save", "unsave", "deleteSaved", "reopenSaved"]
        for verb in tabGroup + colors.map({ "color.\($0)" }) {
            #expect(ids.contains("tabGroup.\(verb)"), "tabGroup.\(verb)")
        }
        let workspaceGroup = ["newWorkspace", "rename", "setColor", "togglePin", "collapse", "expand", "ungroup",
                              "closeWorkspaces", "delete", "moveUp", "moveDown", "moveToWindow", "moveToNewWindow",
                              "markRead", "markUnread", "clearNotifications", "editConfig"]
        for verb in workspaceGroup + colors.map({ "color.\($0)" }) {
            #expect(ids.contains("workspaceGroup.\(verb)"), "workspaceGroup.\(verb)")
        }
        for id in ["newWorkspaceGroup", "groupSelectedWorkspaces", "toggleFocusedWorkspaceGroupCollapsed",
                   "moveWorkspaceToGroup", "removeWorkspaceFromGroup"] {
            #expect(ids.contains(id), "\(id)")
        }
    }

    @Test func contextMenuRendersFromRegistry() throws {
        let registry = ActionRegistry.standard()
        var renamed: [ActionInvocation] = []
        registry.bind("tabGroup.rename", invoke: { renamed.append($0) })
        registry.bind("tabGroup.close") {}
        let target = ActionTargetRef(kind: .tabGroup, id: "g1")
        let menu = registry.makeContextMenu(for: .tabGroup, target: target)

        let titles = menu.items.map(\.title)
        #expect(titles.contains(try #require(registry.title(for: "tabGroup.close"))))
        let colorItem = try #require(menu.items.first { $0.submenu != nil })
        #expect(colorItem.submenu?.items.count == 9)
        #expect(!(menu.items.first?.isSeparatorItem ?? true))
        #expect(!(menu.items.last?.isSeparatorItem ?? true))

        let close = try #require(menu.items.first { $0.title == registry.title(for: "tabGroup.close") })
        #expect((close.target as? any NSMenuItemValidation)?.validateMenuItem(close) == true)
        let ungroup = try #require(menu.items.first { $0.title == registry.title(for: "tabGroup.ungroup") })
        #expect((ungroup.target as? any NSMenuItemValidation)?.validateMenuItem(ungroup) == false)

        // Rename needs a name: with no collector the handler still gets the target.
        let rename = try #require(menu.items.first { $0.title == registry.title(for: "tabGroup.rename") })
        _ = (rename.target as? NSObject)?.perform(rename.action, with: rename)
        #expect(renamed.first?.target == target)
    }

    @Test func contextMenuHidesActionsThatDoNotApply() {
        let registry = ActionRegistry.standard()
        let paneTitles = registry.makeContextMenu(for: .pane).items.map(\.title)
        #expect(!paneTitles.contains(registry.title(for: "browserReload") ?? "?"))
        let pageTitles = registry.makeContextMenu(for: .browserPage).items.map(\.title)
        #expect(pageTitles.contains(registry.title(for: "browserReload") ?? "?"))
    }

    @Test func missingArgumentsGoToTheCollector() {
        let registry = ActionRegistry.standard()
        var ran: [ActionInvocation] = []
        var collected: [(ActionID, ActionInvocation)] = []
        registry.bind("tabGroup.setColor", invoke: { ran.append($0) })
        registry.argumentCollector = { collected.append(($0, $1)) }

        let target = ActionTargetRef(kind: .tabGroup, id: "g1")
        #expect(registry.perform("tabGroup.setColor", invocation: ActionInvocation(target: target)))
        #expect(ran.isEmpty)
        #expect(collected.first?.0 == "tabGroup.setColor")
        #expect(collected.first?.1.target == target)

        #expect(registry.perform("tabGroup.setColor", invocation: ActionInvocation(target: target, arguments: ["color": .string("green")])))
        #expect(ran.first?["color"] == .string("green"))
    }

    @Test func argumentParsing() throws {
        let color = try #require(ActionCatalog.all.first { $0.id == "tabGroup.setColor" }?.arguments.first)
        #expect(color.parse("blue") == .string("blue"))
        #expect(color.parse("teal") == nil)
        let index = try #require(ActionCatalog.all.first { $0.id == "selectWorkspaceByNumber" }?.arguments.first)
        #expect(index.parse("3") == .int(3))
        #expect(index.parse("12") == nil)
        let workspace = try #require(ActionCatalog.all.first { $0.id == "goToWorkspace" }?.arguments.first)
        #expect(workspace.parse("workspace:w2") == .target(ActionTargetRef(kind: .workspace, id: "w2")))
        #expect(ActionTargetRef(parsing: "tab-group:g1") == ActionTargetRef(kind: .tabGroup, id: "g1"))
        #expect(ActionTargetRef(parsing: "nope:1") == nil)
    }

    @Test func mainMenuItemsComeFromTheRegistry() {
        let registry = ActionRegistry.standard()
        let appMenu = registry.makeMainMenuItems(for: .app).map(\.title)
        #expect(appMenu.contains(registry.title(for: "quit") ?? "?"))
        #expect(appMenu.contains(registry.title(for: "openSettings") ?? "?"))
        for menu in ActionMainMenu.allCases {
            #expect(!registry.makeMainMenuItems(for: menu).isEmpty, "\(menu)")
        }
    }
}
