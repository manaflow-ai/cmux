public import AppKit

extension ActionInvocation {
    /// The arguments of a tab menu opened on one of several selected tabs (the strip's
    /// multi-selection): its tab rows act on every selected tab, as in Chrome.
    public static let tabSelectionArguments: [String: ActionValue] = ["tabSelection": .bool(true)]

    /// A tab menu row run on one of several selected tabs: it acts on all of them.
    public var actsOnTabSelection: Bool { arguments["tabSelection"]?.boolValue == true }
}

extension NSMenu {
    /// A tab menu opened on several selected tabs names what its rows do to them (Chrome's Close
    /// Tabs, Pin Tabs). `pins`: Pin pins them (one is unpinned); else every one is pinned and it unpins.
    @discardableResult
    public func namingTabSelection(pins: Bool) -> NSMenu {
        for item in items {
            item.submenu?.namingTabSelection(pins: pins)
            guard let id = ActionRegistry.menuRun(of: item)?.id, let title = Self.tabSelectionTitle(id, pins: pins) else { continue }
            item.title = title
        }
        return self
    }

    /// The title of `id`'s row (and palette row) while it acts on several selected tabs; nil keeps
    /// the action's own title. `pins`: as in ``namingTabSelection(pins:)``.
    public static func tabSelectionTitle(_ id: ActionID, pins: Bool) -> String? {
        switch id.rawValue {
        case "closeTab": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.close") + "\u{E002}" + String(localized: "tabSelection.close", defaultValue: "Close Tabs", bundle: .module))
        case "palette.toggleTabPin": pins ? ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.pin") + "\u{E002}" + String(localized: "tabSelection.pin", defaultValue: "Pin Tabs", bundle: .module))
            : ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.unpin") + "\u{E002}" + String(localized: "tabSelection.unpin", defaultValue: "Unpin Tabs", bundle: .module))
        case "duplicateTab": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.duplicate") + "\u{E002}" + String(localized: "tabSelection.duplicate", defaultValue: "Duplicate Tabs", bundle: .module))
        case "palette.moveTabToNewWorkspace":
            ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.moveToNewWorkspace") + "\u{E002}" + String(localized: "tabSelection.moveToNewWorkspace", defaultValue: "Move Tabs to New Workspace", bundle: .module))
        case "tab.moveToNewWindow": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.moveToNewWindow") + "\u{E002}" + String(localized: "tabSelection.moveToNewWindow", defaultValue: "Move Tabs to New Window", bundle: .module))
        case "tabGroup.create": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.createGroup") + "\u{E002}" + String(localized: "tabSelection.createGroup", defaultValue: "Add Tabs to New Group", bundle: .module))
        case "tabGroup.addTab": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.addToGroup") + "\u{E002}" + String(localized: "tabSelection.addToGroup", defaultValue: "Add Tabs to Group…", bundle: .module))
        case "tabGroup.removeTab": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.removeFromGroup") + "\u{E002}" + String(localized: "tabSelection.removeFromGroup", defaultValue: "Remove Tabs from Group", bundle: .module))
        case "tab.stash": ("\u{E000}Localizable\u{E001}" + String(describing: "tabSelection.stash") + "\u{E002}" + String(localized: "tabSelection.stash", defaultValue: "Save and Close Tabs", bundle: .module))
        default: nil
        }
    }
}
