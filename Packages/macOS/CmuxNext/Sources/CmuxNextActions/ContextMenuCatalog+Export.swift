import Foundation

// The right-click menus in `plans/cmux-next/action-surfaces.json`
// (`context_menus`), so other clients (GPUI) build the same menus without
// parsing Swift: per menu its rows in order, separators, submenus, choice
// lists and folders, and the predicates that show or enable each row.
// `ContextMenuExportParityTests` renders this export with the same rules as
// `ActionRegistry.makeContextMenu` and compares it with the live menus.
nonisolated extension ContextMenuCatalog {
    /// How a client renders `context_menus` (the registry's rules).
    public static let exportRenderRules: [String] = [
        "A row shows only when its visible_when holds: every name in requires is true in the effective context (the window's context plus the menu's implied names), debug_only rows need developer tools, and a row whose feature an administrator turned off is left out.",
        "enabled_when can_perform: the row is enabled when its action is bound and its handler allows it for the clicked target; a disabled row may carry a reason as subtitle and tooltip.",
        "A row with a label shows that label instead of its action's title: menu-only wording (Set Icon… for Set Space Icon…); the palette and CLI keep the title.",
        "A submenu takes its label, else its action's title, without a trailing ellipsis; a folder takes its own title. A submenu or folder without a shown row is left out.",
        "A separator shows only after a shown row and before another shown row: runs collapse to one, and leading and trailing separators drop.",
        "A choices row is a submenu with one item per value in choices.values (then a separator and More… when more_opens_palette). It shows by the same visible_when as every row, and only when its action is bound and enabled (otherwise it is left out, not disabled).",
        "A choices row with choices.trailer ends its submenu with that action under its own title, on the same target, after a separator when there are values. With a trailer the row shows even when it has no values (Move Workspace to Group > Move Workspace to New Group).",
        "context_menus_not_exported lists the menus built by hand in their views; they are not in context_menus. Whoever adds a new hand-built menu adds it to that list (ContextMenuCatalog.exportHandBuiltMenus).",
    ]

    /// Menus built by hand in their views, not from the catalog, so not in
    /// `context_menus` yet (a known gap; GPUI asks for one when it needs it):
    /// name and the source that builds it. A new hand-built NSMenu must be
    /// added here (no source scan checks this).
    public static let exportHandBuiltMenus: [[String: String]] = [
        ["name": "remoteHoverToolbar", "source": "CmuxNextRemoteView/Pane/RemoteHoverToolbar.swift"],
        ["name": "terminalPaste", "source": "CmuxNextTerminal/TerminalSurfaceView+Pasteboard.swift"],
        ["name": "browserBackForward", "source": "CmuxNextBrowser/UI/BrowserChromeView+BackForwardMenu.swift"],
        ["name": "browserExtensions", "source": "CmuxNextBrowser/UI/ExtensionsMenu.swift"],
        ["name": "browserEnginePage", "source": "CmuxNextBrowser/UI/BrowserContextMenuBuilder.swift"],
        ["name": "browserDevToolsDivider", "source": "CmuxNextBrowser/CEF/CEFDevToolsDivider.swift"],
        ["name": "browserProfileLink", "source": "CmuxNextApp/BrowserProfiles/BrowserProfileLinkMenu.swift"],
        ["name": "browserToolbar", "source": "CmuxNextApp/Handlers/BrowserToolbarHandlers.swift"],
        ["name": "bookmarkFolder", "source": "CmuxNextBookmarks/UI/BookmarkFolderMenu.swift"],
        ["name": "titlebarHistory", "source": "CmuxNextHistory/TitlebarHistoryMenu.swift"],
        ["name": "notificationRow", "source": "CmuxNextApp/Notifications/Panel/NotificationsPanelController.swift"],
        ["name": "agentPaneMessage", "source": "CmuxNextAgentPane/AgentPaneContextMenu.swift"],
        ["name": "paneToolbarMore", "source": "CmuxNextApp/PaneToolbar.swift"],
        ["name": "browserReload", "source": "CmuxNextBrowser/UI/BrowserReloadMenu.swift"],
        ["name": "browserDownloads", "source": "CmuxNextApp/Handlers/BrowserDownloadsMenu.swift"],
        ["name": "browserMedia", "source": "CmuxNextApp/Handlers/BrowserMediaMenu.swift"],
        ["name": "browserDevice", "source": "CmuxNextBrowser/UI/BrowserDeviceMenu.swift"],
        ["name": "browserMachineBadge", "source": "CmuxNextApp/AppServices+BrowserTabMachines.swift"],
        ["name": "remoteBrowserPage", "source": "CmuxNextRemoteBrowser/Native/RemoteBrowserNativeUI.swift"],
        ["name": "sidebarNoticeCard", "source": "CmuxNextSidebar/Views/SidebarNoticeCardView.swift"],
        ["name": "sidebarUpdateCard", "source": "CmuxNextSidebar/Views/SidebarUpdateCardView.swift"],
        ["name": "debugSidebarToggleIcon", "source": "CmuxNextApp/Windows/SidebarToggleIconMenu.swift"],
        ["name": "debugStatusIconSet", "source": "CmuxNextApp/Windows/StatusIconSetMenu.swift"],
        ["name": "homeBackground", "source": "CmuxNextHomeEngine/HomePageMenus.swift"],
        ["name": "historyToolbar", "source": "CmuxNextHistory/HistoryPageView.swift"],
        ["name": "historyRow", "source": "CmuxNextHistory/HistoryPageRow.swift"],
        ["name": "taskAssignee", "source": "CmuxNextTasks/Views/AssigneeMenu.swift"],
    ]

    /// Every context menu's export, keyed by `ActionMenuContext.exportName`.
    public func exportObject(descriptors: [ActionDescriptor], titles: ActionTitleCatalog = ActionTitleCatalog()) -> [String: Any] {
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var menus: [String: Any] = [:]
        for context in ActionMenuContext.allCases {
            let entries = entries(for: context)
            guard !entries.isEmpty else { continue }
            menus[context.exportName] = [
                "implied": Self.contextNames(ActionRegistry.impliedContext(for: context)),
                "entries": Self.exportEntries(entries, byID: byID, titles: titles, labels: labels(for: context)),
            ] as [String: Any]
        }
        return menus
    }

    static func exportEntries(_ entries: [ContextMenuEntry], byID: [ActionID: ActionDescriptor],
                              titles: ActionTitleCatalog, labels: [ActionID: String] = [:]) -> [[String: Any]] {
        entries.enumerated().map { order, entry in
            var row: [String: Any] = ["order": order]
            switch entry {
            case .separator:
                row["kind"] = "separator"
            case .action(let id), .choices(let id):
                if case .choices = entry { row["kind"] = "choices" } else { row["kind"] = "action" }
                row["id"] = id.rawValue
                row["visible_when"] = visibleWhen(byID[id])
                row["enabled_when"] = "can_perform"
                // A menu-only title (ContextMenuPlacement.label), English.
                if let label = labels[id] { row["label"] = label }
                if case .choices = entry, let (argument, cases) = byID[id]?.arguments.lazy.compactMap(ActionRegistry.menuChoices).first {
                    row["choices"] = [
                        "argument": argument.name,
                        "values": cases.map { choice -> [String: Any] in
                            // Localizable choice titles use `argument.value.<value>`; other values (theme names) are not localized.
                            let entry = titles.entry(key: "argument.value.\(choice.value)", table: "Localizable").flatMap { $0.english == choice.title ? $0 : nil }
                            return ["value": choice.value, "title": choice.title,
                                    "title_key": entry.map { $0.key as Any } ?? NSNull(), "title_table": entry.map { $0.table as Any } ?? NSNull()]
                        },
                        "more_opens_palette": argument.suggestions != nil,
                    ] as [String: Any]
                } else if case .choices = entry, let descriptor = byID[id],
                          let argument = descriptor.arguments.first(where: { ActionTargetChoices.kind(of: $0, in: descriptor) != nil }),
                          let kind = ActionTargetChoices.kind(of: argument, in: descriptor) {
                    // The objects of that kind, listed by the client (the palette's target list).
                    row["choices"] = ["argument": argument.name, "target_kind": kind.rawValue] as [String: Any]
                }
                if case .choices = entry, let trailer = ContextMenuEssentials.choiceTrailers[id], var choices = row["choices"] as? [String: Any] {
                    choices["trailer"] = ["id": trailer.rawValue, "title_from": "action"] as [String: Any]
                    row["choices"] = choices
                }
            case .submenu(let id, let children):
                row["kind"] = "submenu"
                row["id"] = id.rawValue
                row["title_from"] = "action"
                if let label = labels[id] { row["label"] = label }
                row["visible_when"] = visibleWhen(byID[id])
                row["children"] = exportEntries(children, byID: byID, titles: titles, labels: labels)
            case .folder(let folder, let children):
                row["kind"] = "folder"
                row["folder"] = folder.rawValue
                let key = "menu.folder.\(folder.rawValue)"
                row["title"] = titles.entry(key: key, table: "Localizable")?.english ?? folder.title
                row["title_key"] = key
                row["title_table"] = "Localizable"
                row["children"] = exportEntries(children, byID: byID, titles: titles, labels: labels)
            case .group(let group, let children):
                // Only a person's arrangement has these; the generated export never does.
                row["kind"] = "group"
                row["title"] = group.title
                row["children"] = exportEntries(children, byID: byID, titles: titles, labels: labels)
            }
            return row
        }
    }

    static func visibleWhen(_ descriptor: ActionDescriptor?) -> [String: Any] {
        guard let descriptor else { return ["requires": [String](), "debug_only": false, "feature": NSNull()] }
        return [
            "requires": contextNames(descriptor.requires),
            "debug_only": descriptor.isDebugOnly,
            "feature": ActionFeature.feature(of: descriptor).map { $0.rawValue as Any } ?? NSNull(),
        ]
    }

    /// Context bits by their `when` key names, in `ActionContext.keyNames` order.
    static func contextNames(_ context: ActionContext) -> [String] {
        ActionContext.keyNames.compactMap { bit, name in context.contains(bit) ? name : nil }
    }
}

nonisolated extension ActionMenuContext {
    /// The menu's name in the export (`context_menus` keys and each action's
    /// `context_menus`): the raw value, except the Space chip's menu, whose
    /// case predates Spaces (`profile`). Export only: persisted ids and
    /// `action.list` keep the raw value.
    var exportName: String {
        switch self {
        case .profile: "space"
        default: rawValue
        }
    }
}
