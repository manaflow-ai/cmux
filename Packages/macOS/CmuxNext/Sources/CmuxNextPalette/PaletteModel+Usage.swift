import Foundation

/// Row controls of the usage history (plans/cmux-next/palette-ranking.md
/// 5.2): Hide from Palette or Show in Palette, and Reset Ranking, in a
/// row's Actions menu. The usage store (the daemon) owns the result.
extension PaletteModel {
    func usageCommands(for item: PaletteItem) -> [PaletteCommand] {
        guard let key = item.frecencyKey else { return [] }
        var commands: [PaletteCommand] = []
        if usage.canHideRows {
            let isHidden = frecency.hidden.contains(key)
            commands.append(PaletteCommand(
                id: isHidden ? "usage.show" : "usage.hide",
                title: isHidden ? PaletteStrings.showInPalette : PaletteStrings.hideFromPalette,
                symbol: isHidden ? "eye" : "eye.slash",
                effect: .performKeepingOpen { [weak self] in self?.usage.setHidden(key: key, hidden: !isHidden) }
            ))
        }
        if frecency.entries[key] != nil || frecency.picks.contains(where: { $0.key == key }) {
            commands.append(PaletteCommand(
                id: "usage.forget", title: PaletteStrings.resetRanking, symbol: "arrow.counterclockwise",
                effect: .performKeepingOpen { [weak self] in
                    guard let self else { return }
                    usage.forget(key: key)
                    frecency = usage.history
                }
            ))
        }
        return commands
    }
}
