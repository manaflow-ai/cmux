import CmuxNextActions

public final class WorkspacePaletteProvider: PaletteProvider {
    public let id = "workspaces"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteWorkspaceSource

    public init(source: any PaletteWorkspaceSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public static var section: PaletteSection {
        PaletteSection(id: "workspaces", title: PaletteStrings.sectionWorkspaces, order: 10)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.workspaces.map { workspace in
            let id = workspace.id
            var item = PaletteItem(
                id: "workspace:\(id)",
                title: workspace.title,
                subtitle: workspace.directory.map(abbreviatePath),
                accessory: workspace.isSelected ? PaletteStrings.current
                    : (workspace.unreadCount > 0 ? PaletteStrings.unreadCount(workspace.unreadCount) : nil),
                symbol: "rectangle.stack",
                section: Self.section,
                keywords: [PaletteStrings.workspaceKeyword],
                primary: PaletteCommand(id: "select", title: PaletteStrings.switchToWorkspace, symbol: "return", effect: .perform {
                    source.selectWorkspace(id: id)
                }),
                secondary: [
                    PaletteCommand(id: "rename", title: PaletteStrings.renameWorkspace, symbol: "pencil", effect: .textInput(PaletteTextInputSpec(
                        id: "rename-workspace:\(id)",
                        title: PaletteStrings.renameWorkspace,
                        placeholder: PaletteStrings.workspaceNamePlaceholder,
                        initialText: workspace.title,
                        skipsUnchangedText: true,
                        submitTitle: PaletteStrings.renameTo,
                        submit: { source.renameWorkspace(id: id, to: $0) }
                    ))),
                    PaletteCommand(id: "close", title: PaletteStrings.closeWorkspace, symbol: "xmark.square", isDestructive: true, effect: .perform {
                        source.closeWorkspace(id: id)
                    }),
                    PaletteCommand(id: "copyID", title: PaletteStrings.copyID, symbol: "doc.on.doc", effect: .perform {
                        PaletteClipboard.copy(id)
                    }),
                ],
                frecencyKey: "workspace:\(id)",
                rankBias: workspace.isSelected ? -5 : 0
            )
            item.actionRefs = [PaletteActionRef("goToWorkspace", arguments: ["workspace": .target(ActionTargetRef(kind: .workspace, id: id))],
                                                title: PaletteStrings.switchToWorkspace)]
            return item
        }
    }
}
