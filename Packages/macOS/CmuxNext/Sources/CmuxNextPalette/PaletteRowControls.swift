import Foundation

/// Row controls of the usage history (plans/cmux-next/palette-ranking.md
/// 5.2): Hide from Palette or Show in Palette, and Reset Ranking, in a
/// row's Actions. The usage store (the daemon) owns the result.
enum PaletteRowControls {
    @MainActor
    static func commands(for item: PaletteItem, model: PaletteModel) -> [PaletteCommand] {
        guard let key = item.frecencyKey else { return [] }
        let usage = model.usage
        var commands: [PaletteCommand] = []
        if usage.canHideRows {
            let isHidden = model.frecency.hidden.contains(key)
            commands.append(PaletteCommand(
                id: isHidden ? "usage.show" : "usage.hide",
                title: isHidden ? PaletteStrings.showInPalette : PaletteStrings.hideFromPalette,
                symbol: isHidden ? "eye" : "eye.slash",
                effect: .performKeepingOpen { usage.setHidden(key: key, hidden: !isHidden) }
            ))
        }
        if model.frecency.entries[key] != nil || model.frecency.picks.contains(where: { $0.key == key }) {
            commands.append(PaletteCommand(
                id: "usage.forget", title: PaletteStrings.resetRanking, symbol: "arrow.counterclockwise",
                effect: .performKeepingOpen { [weak model] in
                    usage.forget(key: key)
                    model?.frecency = usage.history
                }
            ))
        }
        return commands
    }
}
