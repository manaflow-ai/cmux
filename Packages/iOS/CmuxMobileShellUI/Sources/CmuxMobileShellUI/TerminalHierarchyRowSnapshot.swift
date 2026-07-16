import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

struct TerminalHierarchyRowSnapshot: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let title: String
    let duplicateOrdinal: Int?
    let workspaceName: String
    let paneNumber: Int
    let isSelected: Bool
    let isReady: Bool
    let canClose: Bool
    let requiresCloseConfirmation: Bool

    var displayTitle: String {
        guard let duplicateOrdinal else { return title }
        return String(
            format: L10n.string(
                "mobile.terminal.hierarchy.duplicateTitle",
                defaultValue: "%1$@, %2$d"
            ),
            locale: Locale.current,
            title,
            duplicateOrdinal
        )
    }

    var stateLabel: String {
        if isSelected {
            return L10n.string("mobile.terminal.hierarchy.active", defaultValue: "Active")
        }
        return isReady
            ? L10n.string("mobile.terminal.hierarchy.ready", defaultValue: "Ready")
            : L10n.string("mobile.terminal.hierarchy.starting", defaultValue: "Starting…")
    }

    var accessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.terminal.hierarchy.rowLabel",
                defaultValue: "%1$@, terminal, workspace %2$@, pane %3$d, %4$@"
            ),
            locale: Locale.current,
            displayTitle,
            workspaceName,
            paneNumber,
            stateLabel
        )
    }

    var closeAccessibilityLabel: String {
        String(
            format: L10n.string(
                "mobile.terminal.hierarchy.closeTargetLabel",
                defaultValue: "Close %1$@ terminal in workspace %2$@, pane %3$d"
            ),
            locale: Locale.current,
            displayTitle,
            workspaceName,
            paneNumber
        )
    }

    var closeConsequence: String {
        closeConsequence(requiresProcessConfirmation: requiresCloseConfirmation)
    }

    func closeConsequence(requiresProcessConfirmation: Bool) -> String {
        String(
            format: requiresProcessConfirmation
                ? L10n.string(
                    "mobile.terminal.hierarchy.closeRunningContextMessage",
                    defaultValue: "Close %1$@ in workspace %2$@, pane %3$d. Its running process will end and this cannot be undone."
                )
                : L10n.string(
                    "mobile.terminal.hierarchy.closeContextMessage",
                    defaultValue: "Close %1$@ in workspace %2$@, pane %3$d. Its position will be removed."
                ),
            locale: Locale.current,
            displayTitle,
            workspaceName,
            paneNumber
        )
    }
}
