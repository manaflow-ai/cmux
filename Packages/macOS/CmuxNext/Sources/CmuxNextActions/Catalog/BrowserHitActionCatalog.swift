// The page right-click rows for a link, an image and selected text (R123
// slice B): one menu for both engines, generated from these placements
// (the App's `BrowserHitMenu` passes the hit's `url` and `text`). Each
// row is an action the palette, the CLI and MCP reach with the same
// arguments. Titles live in ActionCatalog.xcstrings (21 languages).

nonisolated enum BrowserHitActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        linkDescriptors() + imageDescriptors() + selectionDescriptors()
    }

    /// The link's address (`url`), required.
    static var linkURL: ActionArgument {
        ActionArgument(name: "url", title: String(localized: "argument.link.url", defaultValue: "Link", bundle: .module), kind: .string)
    }

    /// The image's address (`url`), required.
    static var imageURL: ActionArgument {
        ActionArgument(name: "url", title: String(localized: "argument.browser.imageURL", defaultValue: "Image Address", bundle: .module),
                       kind: .string)
    }

    private static func row(_ id: ActionID, _ title: String, _ keywords: [String], symbol: String, arguments: [ActionArgument],
                            cliName: String? = nil, palette: SurfaceDecision = .offered, cli: SurfaceDecision,
                            placements: [ContextMenuPlacement]) -> ActionDescriptor {
        ActionDescriptor(
            id: id, title: title, keywords: ["browser"] + keywords, category: .browser, symbol: symbol,
            surfaces: [.contextMenu], arguments: arguments, targets: [.tab], cliName: cliName,
            surfacePlan: ActionSurfacePlan(palette: palette, cli: cli, contextMenus: placements)
        )
    }

    private static func p(_ context: ActionMenuContext, _ group: MenuGroup, _ rank: Int) -> ContextMenuPlacement {
        ContextMenuPlacement(context, group, rank)
    }

    // Copying and saving act on the right-clicked element: from the palette
    // they would only echo a typed address back (liveInput). The CLI prints
    // what a copy would write (clipboard) and a save panel is app UI (guiOnly).

    private static func linkDescriptors() -> [ActionDescriptor] {
        [
            row("browser.link.openInNewTab",
                String(localized: "action.browser.link.openInNewTab", defaultValue: "Open Link in New Tab", bundle: .module),
                ["link", "new tab", "background"], symbol: "plus.square.on.square", arguments: [linkURL],
                cliName: "browser open-link-in-new-tab", cli: .offered, placements: [p(.browserLink, .navigate, 0)]),
            row("browser.link.openInNewWindow",
                String(localized: "action.browser.link.openInNewWindow", defaultValue: "Open Link in New Window", bundle: .module),
                ["link", "window"], symbol: "macwindow.badge.plus", arguments: [linkURL],
                cliName: "browser open-link-in-new-window", cli: .offered, placements: [p(.browserLink, .navigate, 1)]),
            row("browser.link.openInNewSpace",
                String(localized: "action.browser.link.openInNewSpace", defaultValue: "Open Link in New Space", bundle: .module),
                ["link", "space", "room"], symbol: "square.stack.3d.up", arguments: [linkURL],
                cliName: "browser open-link-in-new-space", cli: .offered, placements: [p(.browserLink, .navigate, 2)]),
            row("browser.link.openInNewWorkspace",
                String(localized: "action.browser.link.openInNewWorkspace", defaultValue: "Open Link in New Workspace", bundle: .module),
                ["link", "workspace"], symbol: "rectangle.stack.badge.plus", arguments: [linkURL],
                cliName: "browser open-link-in-new-workspace", cli: .offered, placements: [p(.browserLink, .navigate, 3)]),
            row("browser.link.openInSplit",
                String(localized: "action.browser.link.openInSplit", defaultValue: "Open Link in Split Right", bundle: .module),
                ["link", "split", "screen", "side by side", "right"], symbol: "rectangle.split.2x1", arguments: [linkURL],
                cliName: "browser open-link-in-split", cli: .offered, placements: [p(.browserLink, .navigate, 4)]),
            row("browser.link.openInIncognitoWindow",
                String(localized: "action.browser.link.openInIncognitoWindow", defaultValue: "Open Link in Incognito Window", bundle: .module),
                ["link", "incognito", "private", "off the record"], symbol: "eyeglasses", arguments: [linkURL],
                cliName: "browser open-link-in-incognito-window", cli: .offered, placements: [p(.browserLink, .navigate, 100)]),
            row("browser.link.saveAs",
                String(localized: "action.browser.link.saveAs", defaultValue: "Save Link As…", bundle: .module),
                ["link", "download", "save"], symbol: "square.and.arrow.down", arguments: [linkURL],
                palette: .exempt(.liveInput), cli: .exempt(.guiOnly), placements: [p(.browserLink, .inspect, 0)]),
            row("browser.link.copy",
                String(localized: "action.browser.link.copy", defaultValue: "Copy Link", bundle: .module),
                ["link", "address", "url", "clipboard"], symbol: "link", arguments: [linkURL],
                palette: .exempt(.liveInput), cli: .exempt(.clipboard), placements: [p(.browserLink, .inspect, 1)]),
            row("browser.link.copyText",
                String(localized: "action.browser.link.copyText", defaultValue: "Copy Link Text", bundle: .module),
                ["link", "text", "clipboard"], symbol: "text.quote", arguments: [linkURL.optional, CatalogArgument.textString],
                palette: .exempt(.liveInput), cli: .exempt(.clipboard), placements: [p(.browserLink, .inspect, 2)]),
        ]
    }

    private static func imageDescriptors() -> [ActionDescriptor] {
        [
            row("browser.image.openInNewTab",
                String(localized: "action.browser.image.openInNewTab", defaultValue: "Open Image in New Tab", bundle: .module),
                ["image", "picture", "new tab"], symbol: "photo.on.rectangle", arguments: [imageURL],
                cliName: "browser open-image-in-new-tab", cli: .offered, placements: [p(.browserImage, .navigate, 0)]),
            row("browser.image.saveAs",
                String(localized: "action.browser.image.saveAs", defaultValue: "Save Image As…", bundle: .module),
                ["image", "picture", "download", "save"], symbol: "square.and.arrow.down.on.square", arguments: [imageURL],
                palette: .exempt(.liveInput), cli: .exempt(.guiOnly), placements: [p(.browserImage, .inspect, 0)]),
            row("browser.image.copy",
                String(localized: "action.browser.image.copy", defaultValue: "Copy Image", bundle: .module),
                ["image", "picture", "clipboard"], symbol: "doc.on.doc", arguments: [imageURL],
                palette: .exempt(.liveInput), cli: .exempt(.clipboard), placements: [p(.browserImage, .inspect, 1)]),
            row("browser.image.copyAddress",
                String(localized: "action.browser.image.copyAddress", defaultValue: "Copy Image Address", bundle: .module),
                ["image", "address", "url", "clipboard"], symbol: "link", arguments: [imageURL],
                palette: .exempt(.liveInput), cli: .exempt(.clipboard), placements: [p(.browserImage, .inspect, 2)]),
        ]
    }

    private static func selectionDescriptors() -> [ActionDescriptor] {
        [
            row("browser.selection.copy",
                String(localized: "action.browser.selection.copy", defaultValue: "Copy", bundle: .module),
                ["selection", "text", "clipboard"], symbol: "doc.on.doc", arguments: [CatalogArgument.textString],
                palette: .exempt(.liveInput), cli: .exempt(.clipboard), placements: [p(.browserSelection, .edit, 0)]),
            // The menu row reads Search Google for "…" (the omnibar's engine).
            row("browser.selection.search",
                String(localized: "action.browser.selection.search", defaultValue: "Search the Web", bundle: .module),
                ["selection", "search", "google", "web"], symbol: "magnifyingglass", arguments: [CatalogArgument.textString],
                cliName: "browser search-web", cli: .offered, placements: [p(.browserSelection, .navigate, 0)]),
            // The menu row reads Look Up "…"; the dictionary panel is app UI.
            row("browser.selection.lookUp",
                String(localized: "action.browser.selection.lookUp", defaultValue: "Look Up", bundle: .module),
                ["selection", "dictionary", "define", "look up"], symbol: "character.book.closed", arguments: [CatalogArgument.textString],
                palette: .exempt(.liveInput), cli: .exempt(.guiOnly), placements: [p(.browserSelection, .navigate, 1)]),
        ]
    }
}
