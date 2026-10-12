import CmuxNextActions

public final class TabPaletteProvider: PaletteProvider {
    public let id = "tabs"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteTabSource

    public init(source: any PaletteTabSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public static var section: PaletteSection {
        PaletteSection(id: "tabs", title: PaletteStrings.sectionTabs, order: 20)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.tabs.map { tab in
            let id = tab.id
            let symbol: String = switch tab.kind {
            case .terminal: "terminal"
            case .browser: "globe"
            case .other(let symbol): symbol
            }
            var item = PaletteItem(
                id: "tab:\(id)",
                title: tab.title,
                subtitle: tab.workspaceTitle,
                accessory: tab.isSelected ? PaletteStrings.current : nil,
                symbol: symbol,
                section: Self.section,
                keywords: [PaletteStrings.tabKeyword],
                primary: PaletteCommand(id: "select", title: PaletteStrings.switchToTab, symbol: "return", effect: .perform {
                    source.selectTab(id: id)
                }),
                secondary: [
                    PaletteCommand(id: "rename", title: PaletteStrings.renameTab, symbol: "pencil", effect: .textInput(PaletteTextInputSpec(
                        id: "rename-tab:\(id)",
                        title: PaletteStrings.renameTab,
                        placeholder: PaletteStrings.tabNamePlaceholder,
                        initialText: tab.title,
                        skipsUnchangedText: true,
                        submitTitle: PaletteStrings.renameTo,
                        submit: { source.renameTab(id: id, to: $0) }
                    ))),
                    PaletteCommand(id: "close", title: PaletteStrings.closeTab, symbol: "xmark", isDestructive: true, effect: .perform {
                        source.closeTab(id: id)
                    }),
                ],
                frecencyKey: "tab:\(id)"
            )
            let target = ActionTargetRef(kind: .tab, id: id)
            item.actionRefs = [PaletteActionRef("tab.focus", target: target, title: PaletteStrings.switchToTab),
                               PaletteActionRef("closeTab", target: target, title: PaletteStrings.closeTab, isDestructive: true)]
            return item
        }
    }
}
