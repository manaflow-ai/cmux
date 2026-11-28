// Chrome extensions (Chromium tabs). Titles live in Extensions.xcstrings.
// Every action is in the palette, the CLI (`cmux extension ...`) and a
// context menu (the page menu, the Extensions menu or an extension's menu),
// and can take a shortcut in cmux.json; none has a default shortcut.

nonisolated enum ExtensionActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let keywords = ["extension", "extensions", "chrome", "chromium", "addon", "plugin"]
        func descriptor(
            _ id: ActionID, _ title: String, _ symbol: String, _ cli: String, extra: [String] = [],
            arguments: [ActionArgument] = [ExtensionArgument.extensionID],
            surfaces: ActionSurfaces = [.palette, .keyboard, .menu, .contextMenu],
            destructive: Bool = false
        ) -> ActionDescriptor {
            ActionDescriptor(
                id: id, title: title, keywords: keywords + extra, category: .browser, symbol: symbol,
                surfaces: surfaces, arguments: arguments, targets: [.pane], cliName: cli,
                mainMenu: surfaces.contains(.menu) ? .view : nil, destructive: destructive
            )
        }
        return [
            descriptor("browser.extensions.menu", String(localized: "action.extensions.menu", defaultValue: "Extensions…", table: "Extensions", bundle: .module), "puzzlepiece.extension",
                       "extension menu", extra: ["toolbar", "puzzle"], arguments: []),
            descriptor("browser.extensions.manage", String(localized: "action.extensions.manage", defaultValue: "Manage Extensions", table: "Extensions", bundle: .module), "puzzlepiece",
                       "extension manage", extra: ["settings", "list"], arguments: []),
            descriptor("browser.extensions.webStore", String(localized: "action.extensions.webStore", defaultValue: "Open Chrome Web Store", table: "Extensions", bundle: .module), "bag",
                       "extension web-store", extra: ["install", "store", "add"], arguments: []),
            descriptor("browser.extensions.loadUnpacked", String(localized: "action.extensions.loadUnpacked", defaultValue: "Load Unpacked Extension…", table: "Extensions", bundle: .module),
                       "folder.badge.plus", "extension load-unpacked", extra: ["install", "developer", "folder"],
                       arguments: [ExtensionArgument.path]),
            descriptor("browser.extension.run", String(localized: "action.extension.run", defaultValue: "Run Extension", table: "Extensions", bundle: .module), "play",
                       "extension run", extra: ["popup", "click", "action"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.options", String(localized: "action.extension.options", defaultValue: "Extension Options", table: "Extensions", bundle: .module), "gearshape",
                       "extension options", extra: ["settings", "preferences"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.pin", String(localized: "action.extension.pin", defaultValue: "Pin Extension to Toolbar", table: "Extensions", bundle: .module), "pin",
                       "extension pin", extra: ["toolbar", "show"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.unpin", String(localized: "action.extension.unpin", defaultValue: "Unpin Extension from Toolbar", table: "Extensions", bundle: .module), "pin.slash",
                       "extension unpin", extra: ["toolbar", "hide"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.enable", String(localized: "action.extension.enable", defaultValue: "Enable Extension", table: "Extensions", bundle: .module), "checkmark.circle",
                       "extension enable", extra: ["turn on"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.disable", String(localized: "action.extension.disable", defaultValue: "Disable Extension", table: "Extensions", bundle: .module), "slash.circle",
                       "extension disable", extra: ["turn off"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.move", String(localized: "action.extension.move", defaultValue: "Move Pinned Extension", table: "Extensions", bundle: .module), "arrow.left.arrow.right",
                       "extension move", extra: ["reorder", "order", "toolbar", "drag"],
                       arguments: [ExtensionArgument.extensionID, ExtensionArgument.index], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.reload", String(localized: "action.extension.reload", defaultValue: "Reload Extension", table: "Extensions", bundle: .module), "arrow.clockwise",
                       "extension reload", extra: ["restart", "crashed", "refresh"], surfaces: [.palette, .keyboard, .contextMenu]),
            descriptor("browser.extension.remove", String(localized: "action.extension.remove", defaultValue: "Remove Extension", table: "Extensions", bundle: .module), "trash",
                       "extension remove", extra: ["uninstall", "delete"], surfaces: [.palette, .keyboard, .contextMenu], destructive: true),
            descriptor("browser.extension.command", String(localized: "action.extension.command", defaultValue: "Run Extension Shortcut", table: "Extensions", bundle: .module),
                       "command", "extension command", extra: ["shortcut", "keyboard", "commands"],
                       arguments: [ExtensionArgument.extensionID, ExtensionArgument.command], surfaces: [.palette, .keyboard, .contextMenu]),
        ]
    }
}

/// Arguments of the extension actions.
nonisolated enum ExtensionArgument {
    static var extensionID: ActionArgument {
        ActionArgument(name: "extension", title: String(localized: "argument.extension", defaultValue: "Extension", table: "Extensions", bundle: .module), kind: .string)
    }

    static var command: ActionArgument {
        ActionArgument(name: "command", title: String(localized: "argument.extensionCommand", defaultValue: "Shortcut", table: "Extensions", bundle: .module), kind: .string)
    }

    static var index: ActionArgument {
        ActionArgument(name: "index", title: String(localized: "argument.extensionIndex", defaultValue: "Position", table: "Extensions", bundle: .module), kind: .int(0...63))
    }

    static var path: ActionArgument {
        ActionArgument(name: "path", title: String(localized: "argument.extensionPath", defaultValue: "Folder", table: "Extensions", bundle: .module), kind: .string, isRequired: false)
    }
}
