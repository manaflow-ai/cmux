import CmuxNextActions
import CmuxNextDesign
import AppKit
import Foundation

public final class SettingsPaletteProvider: PaletteProvider {
    public let id = "settings"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteSettingsSource

    public init(source: any PaletteSettingsSource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public static var section: PaletteSection {
        PaletteSection(id: "settings", title: PaletteStrings.sectionSettings, order: 40)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        source.rows.map(item)
    }

    private func item(_ row: PaletteSettingRow) -> PaletteItem {
        let source = source
        let id = row.id
        var item: PaletteItem
        switch row.kind {
        case .toggle(let isOn):
            let next = !isOn
            item = PaletteItem(
                id: "setting:\(id)", title: row.title, subtitle: row.group, accessory: row.value,
                symbol: isOn ? "checkmark.circle.fill" : "circle", section: Self.section,
                keywords: row.keywords + ["setting", "toggle", next ? "enable" : "disable"],
                isEnabled: row.isEnabled,
                primary: PaletteCommand(
                    id: "toggle", title: next ? PaletteStrings.turnOn : PaletteStrings.turnOff, symbol: "switch.2",
                    effect: .performKeepingOpen { source.commit(row: id, option: next ? "on" : "off") }
                ),
                frecencyKey: "setting:\(id)"
            )
            item.actionRefs = [PaletteActionRef("palette.toggleSetting", arguments: ["setting": .string(id), "on": .bool(next)],
                                                title: next ? PaletteStrings.turnOn : PaletteStrings.turnOff)]
        case .options(let options, let custom):
            item = PaletteItem(
                id: "setting:\(id)", title: row.title, subtitle: row.group, accessory: row.value,
                symbol: "slider.horizontal.3", section: Self.section, keywords: row.keywords + ["setting"],
                isEnabled: row.isEnabled,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return",
                                        effect: .deferred { .push(Self.valuesPage(row, options, custom, source)) }),
                frecencyKey: "setting:\(id)"
            )
        }
        item.swatches = row.swatches
        return item
    }

    /// The value list of one setting: the current value selected; the
    /// highlight previews live, Return writes and closes, leaving reverts.
    static func valuesPage(_ row: PaletteSettingRow, _ options: [PaletteSettingOption], _ custom: PaletteSettingCustomInput?,
                           _ source: any PaletteSettingsSource) -> PalettePageSpec {
        let id = row.id
        let section = PaletteSection(id: "setting-values", title: row.title, order: 0)
        var items = options.map { option in
            var item = PaletteItem(
                id: "option:\(option.id)", title: option.title, accessory: option.isCurrent ? PaletteStrings.current : nil,
                symbol: option.isCurrent ? "checkmark" : "circle", section: section,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return",
                                        effect: .perform { source.commit(row: id, option: option.id) }),
                frecencyKey: nil
            )
            item.swatches = option.swatches
            return item
        }
        if let custom {
            items.append(PaletteItem(
                id: "custom", title: PaletteStrings.customValue, symbol: "square.and.pencil", section: section,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return", effect: .textInput(PaletteTextInputSpec(
                    id: "setting-custom:\(id)", title: row.title, placeholder: custom.placeholder, symbol: "square.and.pencil",
                    submitTitle: { PaletteStrings.submitText(title: row.title, text: $0) },
                    isValid: custom.isValid,
                    next: { text in .perform { source.commit(row: id, text: text) } }
                ))),
                frecencyKey: nil
            ))
        }
        var page = PalettePageSpec(
            id: "setting:\(id)", title: row.title, placeholder: row.title, symbol: "slider.horizontal.3",
            providers: [StaticPaletteProvider(id: "setting-values", items: items)],
            keepsSectionOrder: true,
            emptyQuerySelection: options.firstIndex(where: \.isCurrent) ?? 0
        )
        page.onHighlight = { item in
            source.preview(row: id, option: item.flatMap { $0.id.hasPrefix("option:") ? String($0.id.dropFirst("option:".count)) : nil })
        }
        page.onLeave = { source.preview(row: id, option: nil) }
        return page
    }
}

public final class RecentDirectoriesPaletteProvider: PaletteProvider {
    public let id = "recentDirectories"
    public let showsItemsForEmptyQuery: Bool
    private let source: any PaletteRecentDirectorySource

    public init(source: any PaletteRecentDirectorySource, showsItemsForEmptyQuery: Bool) {
        self.source = source
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    // A palette reset (Cmd-Shift-P reopen) can release this inside an
    // action's task-local scope or from a search task; teardown must not
    // need a main-actor hop (RegistryPaletteProvider, #17590).
    nonisolated deinit {}

    public static var section: PaletteSection {
        PaletteSection(id: "recentDirectories", title: PaletteStrings.sectionRecentDirectories, order: 50)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.recentDirectories.enumerated().map { position, path in
            PaletteItem(
                id: "directory:\(path)",
                title: (path as NSString).lastPathComponent,
                subtitle: abbreviatePath(path),
                symbol: "folder",
                section: Self.section,
                keywords: ["directory", "folder", "project"],
                primary: PaletteCommand(id: "open", title: PaletteStrings.openInNewWorkspace, symbol: "return", effect: .perform {
                    source.openDirectory(path)
                }),
                secondary: [
                    PaletteCommand(id: "copyPath", title: PaletteStrings.copyPath, symbol: "doc.on.doc", effect: .perform {
                        PaletteClipboard.copy(path)
                    }),
                ],
                frecencyKey: "directory:\(path)",
                rankBias: -min(position, 10)
            )
        }
    }
}
