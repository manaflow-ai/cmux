import Bonsplit
import Foundation

extension DockSplitStore {
    /// Resolves the visible, automatic, and custom title metadata shared by
    /// Dock transfers and session persistence. A live Bonsplit tab is the
    /// ownership source of truth. Without a tab, the live panel owns automatic
    /// titles while transfer metadata owns only explicit custom titles and an
    /// active restore boundary.
    func resolvedDockTitleMetadata(
        panel: any Panel,
        transfer: Workspace.DetachedSurfaceTransfer?,
        tab: Bonsplit.Tab?
    ) -> (
        title: String,
        cachedTitle: String,
        customTitle: String?,
        customTitleSource: Workspace.CustomTitleSource?
    ) {
        guard let tab else {
            if let customTitle = transfer?.customTitle {
                return (
                    title: customTitle,
                    cachedTitle: panel.displayTitle,
                    customTitle: customTitle,
                    customTitleSource: transfer?.customTitleSource
                )
            }
            if transfer?.restoredPanelTitleBoundary != nil {
                let restoredTitle = transfer?.title
                    ?? transfer?.cachedTitle
                    ?? panel.displayTitle
                return (
                    title: restoredTitle,
                    cachedTitle: restoredTitle,
                    customTitle: nil,
                    customTitleSource: nil
                )
            }
            // Outside a restore boundary, the live panel is newer than the
            // immutable transfer snapshot even while no Bonsplit tab exists.
            return (
                title: panel.displayTitle,
                cachedTitle: panel.displayTitle,
                customTitle: nil,
                customTitleSource: nil
            )
        }

        let customTitle = tab.hasCustomTitle ? tab.title : nil
        let customTitleSource: Workspace.CustomTitleSource? = if let customTitle {
            customTitle == transfer?.customTitle
                ? transfer?.customTitleSource
                : .user
        } else {
            nil
        }
        let cachedTitle = tab.hasCustomTitle ? panel.displayTitle : tab.title
        return (
            title: tab.title,
            cachedTitle: cachedTitle,
            customTitle: customTitle,
            customTitleSource: customTitleSource
        )
    }

}
