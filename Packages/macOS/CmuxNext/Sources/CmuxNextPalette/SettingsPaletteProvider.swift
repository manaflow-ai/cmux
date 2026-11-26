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
        let rows = source.rows
        let fontRows = rows.filter(Self.isFontRow)
        return (fontRows.isEmpty ? [] : [changeFontItem(fontRows)]) + rows.map(item) + source.navigationItems
    }

    /// The rows Change Font… lists: every font family setting and every setting whose key names a
    /// font (sizes, line heights, the chat's and the Markdown viewer's font), so a new one joins
    /// with no edit here.
    static func isFontRow(_ row: PaletteSettingRow) -> Bool {
        row.isFontFamily || row.id.localizedCaseInsensitiveContains("font")
    }

    /// Change Font…: one page of the font settings (terminal, chat, code, editor, Markdown), each
    /// opening its value list, where the fonts draw in their own face, recent ones first.
    private func changeFontItem(_ rows: [PaletteSettingRow]) -> PaletteItem {
        let section = PaletteSection(id: "fonts", title: PaletteStrings.changeFont, order: 0)
        let items = rows.map { row in
            var item = item(row)
            item.section = section
            item.isDemoted = false
            return item
        }
        let page = PalettePageSpec(
            id: "settings:fonts", title: PaletteStrings.changeFont, placeholder: PaletteStrings.changeFont, symbol: "textformat",
            providers: [StaticPaletteProvider(id: "font-settings", items: items)], keepsSectionOrder: true
        )
        return PaletteItem(
            id: "settings:changeFont", title: PaletteStrings.changeFont, symbol: "textformat", section: Self.section,
            keywords: ["font", "fonts", "typeface", "family", "terminal", "chat", "code", "editor", "markdown", "size", "line height"],
            primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return", effect: .push(page)),
            frecencyKey: "settings:changeFont"
        )
    }

    private func item(_ row: PaletteSettingRow) -> PaletteItem {
        let source = source
        let id = row.id
        var item: PaletteItem
        switch row.kind {
        case .toggle(let isOn):
            let next = !isOn
            // The state shows as every row that flips a state shows it (`PaletteToggleStyle`): the trailing
            // On/Off, not this row's own value text beside a command row's other look (Leo 2026-11-07: "just unify").
            let shown = PaletteTunables.toggleStyle.value.apply(title: row.title, symbol: "slider.horizontal.3", isOn: isOn)
            item = PaletteItem(
                id: "setting:\(id)", title: shown.title, subtitle: row.group,
                symbol: shown.symbol, section: Self.section,
                keywords: row.keywords + ["setting", "toggle", next ? "enable" : "disable"],
                isEnabled: row.isEnabled,
                primary: PaletteCommand(
                    id: "toggle", title: next ? PaletteStrings.turnOn : PaletteStrings.turnOff, symbol: "switch.2",
                    effect: .performKeepingOpen { source.commit(row: id, option: next ? "on" : "off") }
                ),
                frecencyKey: "setting:\(id)"
            )
            item.toggleState = isOn
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
        if source.revealsInSettings {
            revealInSettings(&item, row)
        }
        item.swatches = row.swatches
        item.isDemoted = true
        return item
    }

    /// Show in Settings (Cmd-Return, and the Actions menu): opens the Settings page at the row, its
    /// section open and the row focused (`openSettings setting:`), so typing a setting's name in the
    /// palette is a way into Settings too. A setting the palette has no values for (a list, a set of
    /// sound rules) does that on Return: the Settings page is where it is edited.
    private func revealInSettings(_ item: inout PaletteItem, _ row: PaletteSettingRow) {
        let source = source
        let id = row.id
        let reveal = PaletteCommand(id: "showInSettings", title: PaletteStrings.showInSettings, symbol: "gearshape",
                                    effect: .perform { source.reveal(row: id) })
        let ref = PaletteActionRef("openSettings", arguments: ["setting": .string(id)], title: PaletteStrings.showInSettings)
        if case .options(let options, .none) = row.kind, options.isEmpty {
            item.primary = reveal
            item.actionRefs = [ref]
        } else {
            item.alternate = reveal
            // A toggle's first ref stays its toggle; a value list has no headless primary, so adds none.
            if !item.actionRefs.isEmpty { item.actionRefs.append(ref) }
        }
    }

    /// The value list of one setting: the current value selected; the
    /// highlight previews live, Return writes and closes, leaving reverts.
    static func valuesPage(_ row: PaletteSettingRow, _ options: [PaletteSettingOption], _ custom: PaletteSettingCustomInput?,
                           _ source: any PaletteSettingsSource) -> PalettePageSpec {
        let id = row.id
        let section = PaletteSection(id: "setting-values", title: row.title, order: 0)
        var items = options.map { option in
            var item = PaletteItem(
                id: "option:\(option.id)", title: option.title,
                accessory: option.isCurrent ? PaletteStrings.current : option.isRecent ? PaletteStrings.sectionRecent : nil,
                symbol: option.isCurrent ? "checkmark" : "circle", section: section,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.choose, symbol: "return",
                                        effect: .perform { source.commit(row: id, option: option.id) }),
                frecencyKey: nil
            )
            item.swatches = option.swatches
            item.fontFamily = option.fontFamily
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
