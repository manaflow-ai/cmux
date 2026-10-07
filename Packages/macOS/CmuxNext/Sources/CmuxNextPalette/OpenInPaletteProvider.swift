

public final class OpenInPaletteProvider: PaletteProvider {
    public let id = "openIn"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteOpenInSource

    public init(source: any PaletteOpenInSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public static var section: PaletteSection {
        PaletteSection(id: "openIn", title: PaletteStrings.sectionOpenIn, order: 30)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        let directory = source.currentDirectory.map(abbreviatePath)
        return source.apps.map { app in
            let id = app.id
            return PaletteItem(
                id: "openIn:\(id)",
                title: PaletteStrings.openIn(app.name),
                subtitle: directory,
                symbol: app.symbol,
                section: Self.section,
                keywords: [app.name, "open in", "reveal"],
                primary: PaletteCommand(id: "open", title: PaletteStrings.open, symbol: "return", effect: .perform {
                    source.open(appID: id)
                }),
                frecencyKey: "openIn:\(id)"
            )
        }
    }
}
