import CmuxNextActions
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

    public static var section: PaletteSection {
        PaletteSection(id: "settings", title: PaletteStrings.sectionSettings, order: 40)
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    func makeItems() -> [PaletteItem] {
        let source = source
        return source.toggles.map { toggle in
            let id = toggle.id
            let next = !toggle.isOn
            var item = PaletteItem(
                id: "setting:\(id)",
                title: toggle.title,
                accessory: toggle.isOn ? PaletteStrings.on : PaletteStrings.off,
                symbol: toggle.isOn ? "checkmark.circle.fill" : "circle",
                section: Self.section,
                keywords: toggle.keywords + ["setting", "toggle", next ? "enable" : "disable"],
                primary: PaletteCommand(
                    id: "toggle",
                    title: next ? PaletteStrings.turnOn : PaletteStrings.turnOff,
                    symbol: "switch.2",
                    effect: .performKeepingOpen { source.setToggle(id: id, isOn: next) }
                ),
                frecencyKey: "setting:\(id)"
            )
            item.actionRefs = [PaletteActionRef("palette.toggleSetting", arguments: ["setting": .string(id), "on": .bool(next)],
                                                title: next ? PaletteStrings.turnOn : PaletteStrings.turnOff)]
            return item
        }
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
