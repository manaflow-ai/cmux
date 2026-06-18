import Bonsplit
import CmuxSettings
import Foundation

struct CloseOtherTabsConfirmationPrompt: Sendable {
    let title: String
    let message: String

    init(titles: [String]) {
        let count = titles.count
        let titleLines = titles.map { "• \($0)" }.joined(separator: "\n")
        title = String(localized: "dialog.closeOtherTabs.title", defaultValue: "Close other tabs?")

        if count == 1 {
            let format = String(
                localized: "dialog.closeOtherTabs.message.one",
                defaultValue: "This will close 1 tab in this pane:\n%@"
            )
            message = String(format: format, locale: .current, titleLines)
        } else {
            let format = String(
                localized: "dialog.closeOtherTabs.message.other",
                defaultValue: "This will close %1$lld tabs in this pane:\n%2$@"
            )
            message = String(format: format, locale: .current, Int64(count), titleLines)
        }
    }

    static func displayTitle(_ title: String?) -> String {
        let collapsed = title?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let collapsed, !collapsed.isEmpty {
            return collapsed
        }
        return String(localized: "tab.untitled", defaultValue: "Untitled Tab")
    }
}

extension Workspace {
    func closeTabsFromContextMenu(_ tabIds: [TabID], skipPinned: Bool = true) {
        let confirmationManager = owningTabManager
            ?? AppDelegate.shared?.tabManagerFor(tabId: id)
            ?? AppDelegate.shared?.tabManager

        guard confirmationManager?.isCloseConfirmationInFlight != true else { return }

        let candidates = tabIds.compactMap { tabId -> (tabId: TabID, panelId: UUID?)? in
            let panelId = panelIdFromSurfaceId(tabId)
            if skipPinned, let panelId, isPanelPinned(panelId) {
                return nil
            }
            return (tabId, panelId)
        }
        guard !candidates.isEmpty else { return }

        let needsConfirmation = candidates.contains { candidate in
            guard let panelId = candidate.panelId else { return false }
            return panelNeedsConfirmClose(panelId: panelId)
        }

        if CloseTabWarningStore(defaults: .standard).shouldConfirmClose(
            requiresConfirmation: needsConfirmation,
            source: .shortcut
        ) {
            guard let confirmationManager else { return }
            let prompt = CloseOtherTabsConfirmationPrompt(
                titles: candidates.map { candidate in
                    CloseOtherTabsConfirmationPrompt.displayTitle(
                        candidate.panelId.flatMap { panelTitle(panelId: $0) }
                    )
                }
            )
            guard confirmationManager.confirmClose(
                title: prompt.title,
                message: prompt.message,
                acceptCmdD: false
            ) else { return }
        }

        for candidate in candidates {
            // Remote tmux mirror tabs: the batch prompt above already covered
            // them (panelNeedsConfirmClose is mirror-aware), so route the kill
            // to the remote directly and veto local close. If routing fails
            // while reconnecting, keep the tab so the mirror can retry later.
            // A local force-close would bypass the shouldCloseTab kill routing
            // and leave the remote window alive, resurrecting the tab on the
            // next rebuild.
            switch routeRemoteTmuxNonInteractiveTabCloseIfNeeded(candidate.tabId) {
            case .routed, .rejectedMirrorTab:
                continue
            case .notMirrorTab:
                break
            }
            _ = requestCloseTabRecordingHistory(candidate.tabId, force: needsConfirmation)
        }
    }
}
