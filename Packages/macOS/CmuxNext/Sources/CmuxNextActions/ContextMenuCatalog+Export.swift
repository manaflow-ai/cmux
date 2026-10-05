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
        "A submenu takes its action's title without a trailing ellipsis; a folder takes its own title. A submenu or folder without a shown row is left out.",
        "A separator shows only after a shown row and before another shown row: runs collapse to one, and leading and trailing separators drop.",
        "A choices row is a submenu with one item per value in choices.values (then a separator and More… when more_opens_palette). It shows by the same visible_when as every row, and only when its action is bound and enabled (otherwise it is left out, not disabled).",
    ]

    /// Menus built by hand in their views, not from the catalog, so not in
    /// `context_menus` yet (a known gap; GPUI asks for one when it needs it):
    /// name and the source that builds it.
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
        ["name": "titlebarHistory", "source": "CmuxNextApp/Windows/TitlebarHistoryMenu.swift"],
        ["name": "notificationRow", "source": "CmuxNextApp/Notifications/Panel/NotificationsPanelController.swift"],
        ["name": "homeTranscriptRow", "source": "CmuxNextHome/NativeTranscript/HomeRowHostView.swift"],
        ["name": "onboardingImportProfile", "source": "CmuxNextOnboarding/Variants/Import/ImportProfileMenu.swift"],
    ]

    /// Every context menu's export, keyed by `ActionMenuContext` raw value.
    public func exportObject(descriptors: [ActionDescriptor], titles: ActionTitleCatalog = ActionTitleCatalog()) -> [String: Any] {
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var menus: [String: Any] = [:]
        for context in ActionMenuContext.allCases {
            let entries = entries(for: context)
            guard !entries.isEmpty else { continue }
            menus[context.rawValue] = [
                "implied": Self.contextNames(ActionRegistry.impliedContext(for: context)),
                "entries": Self.exportEntries(entries, byID: byID, titles: titles),
            ] as [String: Any]
        }
        return menus
    }

    static func exportEntries(_ entries: [ContextMenuEntry], byID: [ActionID: ActionDescriptor],
                              titles: ActionTitleCatalog) -> [[String: Any]] {
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
                }
            case .submenu(let id, let children):
                row["kind"] = "submenu"
                row["id"] = id.rawValue
                row["title_from"] = "action"
                row["visible_when"] = visibleWhen(byID[id])
                row["children"] = exportEntries(children, byID: byID, titles: titles)
            case .folder(let folder, let children):
                row["kind"] = "folder"
                row["folder"] = folder.rawValue
                let key = "menu.folder.\(folder.rawValue)"
                row["title"] = titles.entry(key: key, table: "Localizable")?.english ?? folder.title
                row["title_key"] = key
                row["title_table"] = "Localizable"
                row["children"] = exportEntries(children, byID: byID, titles: titles)
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
