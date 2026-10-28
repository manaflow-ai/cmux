import AppKit
import CmuxNextActions
import Testing

/// The action contract (plans/cmux-next/REWRITE.md): every action reaches
/// every entrypoint, menus reference real actions, names are unique.
@Suite struct ActionContractTests {
    let catalog = ActionCatalog.all

    /// `remote.openRemote` is a top-level verb from #25092; rename to a
    /// noun-verb form (e.g. `remote open`) when its owner next touches it.
    static let topLevelVerbs: [ActionID: String] = ["remote.openRemote": "open-remote"]

    @Test func everyActionHasAUniqueNounVerbCLIName() {
        var seen: [String: ActionID] = [:]
        for descriptor in catalog {
            let parts = descriptor.cliName.split(separator: " ")
            if let verb = Self.topLevelVerbs[descriptor.id] {
                #expect(descriptor.cliName == verb, "\(descriptor.id): \(descriptor.cliName)")
            } else {
                #expect(parts.count == 2, "\(descriptor.id): \(descriptor.cliName)")
            }
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
    /// rows act on the right-clicked element; Archive Chief and Open
    /// Conversation act on a row of the Home page's list, and Open Chief Subagent on a row of the Chief
    /// pane's Subagents menu, and Pin or Unpin Chat on a row of the sidebar's chat history; Send Message… and Send to (Chief)… act on
    /// the right-clicked object or selection, and Send Message To… is their palette row; Start Agent from
    /// Any App and Message the Chief from Any App are the system-wide keys of Start Agent and Message the
    /// Chief, whose rows they are; the sidebar's Compact
    /// and Comfortable rows are the app density's "Density: Compact/Comfortable" rows; Mute Tab and
    /// Unmute Tab list in place of the right-click menu's Mute/Unmute Tab toggle).
    @Test func everyActionIsInThePaletteUnlessExempt() {
        for descriptor in catalog where !descriptor.isPaletteVisible {
            let reason = descriptor.surfacePlan.palette.exemption
            #expect(reason != nil, "\(descriptor.id) is hidden from the palette without a reason")
            #expect((reason == .paletteInternal) == descriptor.requires.contains(.paletteOpen), "\(descriptor.id)")
        }
        #expect(catalog.filter { !$0.isPaletteVisible }.map(\.id.rawValue).sorted()
            == (["agent.openSessionTab", "agent.openSessionWorkspace", "browser.findPrevious", "browser.image.copy", "browser.image.copyAddress", "browser.image.saveAs", "browser.link.copy",
                "browser.link.copyText", "browser.link.saveAs", "browser.selection.copy", "browser.selection.lookUp",
                "chief.openSubagent", "commandPaletteNext", "commandPalettePrevious", "history.goTo", "home.archiveChief", "home.deleteChief", "home.messageAbout", "home.messageChiefFromAnyApp", "home.openConversation", "home.sendSelectionTo",
                "home.sendSelectionToChief", "list.next", "list.previous",
                "import.card", "import.list", "import.suggest",
                "omnibar.openInBackgroundTab", "omnibar.openInForegroundTab", "openBrowser.chromium", "palette.startAgentFromAnyApp",
                "sidebar.chat.togglePin", "sidebar.density.comfortable", "sidebar.density.compact", "toggleTabAudioMute"]
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

        // The group's own menu titles its rows without the noun (Close Group), so find them by action.
        func item(_ id: ActionID) -> NSMenuItem? { menu.items.first { ActionRegistry.menuRun(of: $0)?.id == id } }
        #expect(item("tabGroup.close") != nil)
        // Color sits in the Appearance submenu beside Set Icon, so find it at any depth.
        func submenuItems(_ items: [NSMenuItem]) -> [NSMenuItem] {
            items.flatMap { item in item.submenu.map { [item] + submenuItems($0.items) } ?? [] }
        }
        let colorItem = try #require(submenuItems(menu.items).first { $0.submenu?.items.allSatisfy { $0.submenu == nil } ?? false })
        #expect(colorItem.submenu?.items.count == 9)
        #expect(!(menu.items.first?.isSeparatorItem ?? true))
        #expect(!(menu.items.last?.isSeparatorItem ?? true))

        let close = try #require(item("tabGroup.close"))
        #expect((close.target as? any NSMenuItemValidation)?.validateMenuItem(close) == true)
        let ungroup = try #require(item("tabGroup.ungroup"))
        #expect((ungroup.target as? any NSMenuItemValidation)?.validateMenuItem(ungroup) == false)

        // Rename needs a name: with no collector the handler still gets the target.
        let rename = try #require(item("tabGroup.rename"))
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
