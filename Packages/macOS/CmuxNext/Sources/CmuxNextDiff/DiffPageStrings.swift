import Foundation

/// The diff viewer host's strings (table `DiffPage`). The page's own labels
/// ship with the page (webviews/src/labels.ts, English and Japanese).
public nonisolated enum DiffPageStrings {
    public static var tabTitle: String {
        String(localized: "diff.page.tabTitle", defaultValue: "Diff", table: "DiffPage", bundle: .l10n)
    }

    public static var notRepository: String {
        String(localized: "diff.page.notRepository", defaultValue: "This folder is not in a git repository.",
               table: "DiffPage", bundle: .l10n)
    }

    public static var unavailable: String {
        String(localized: "diff.page.unavailable", defaultValue: "The diff viewer is not available in this build.",
               table: "DiffPage", bundle: .l10n)
    }

    /// A diff tab's repository is on `machine` (#25581), which did not answer.
    public static func machineOffline(_ machine: String) -> String {
        String(format: String(localized: "diff.page.machineOffline",
                              defaultValue: "“%@” is not connected. Its diff shows again when it reconnects.",
                              table: "DiffPage", bundle: .l10n), machine)
    }

    /// What a diff tab of another machine's repository cannot do yet: whole files, other bases,
    /// staging, reverting, the editor app and Finder all read or change this Mac's disk.
    public static var machineUnsupported: String {
        String(localized: "diff.page.machineUnsupported", defaultValue: "This is not available for a repository on another machine yet.",
               table: "DiffPage", bundle: .l10n)
    }

    static var noFolder: String {
        String(localized: "diff.page.noFolder", defaultValue: "The focused pane has no folder to diff.",
               table: "DiffPage", bundle: .l10n)
    }

    public static var noDiffTab: String {
        String(localized: "diff.page.noDiffTab", defaultValue: "No diff viewer has the keyboard.",
               table: "DiffPage", bundle: .l10n)
    }

    static var chooseFolder: String {
        String(localized: "diff.page.chooseFolder", defaultValue: "Choose a folder to diff", table: "DiffPage", bundle: .l10n)
    }

    static var chooseButton: String {
        String(localized: "diff.page.chooseButton", defaultValue: "Open Diff", table: "DiffPage", bundle: .l10n)
    }

    static var pullRequestFailed: String {
        String(localized: "diff.page.pullRequestFailed", defaultValue: "The pull request could not be opened. Try again.",
               table: "DiffPage", bundle: .l10n)
    }

    // MARK: Revert (DiffPageProvider+Revert.swift)

    static var revertOneTitle: String {
        String(localized: "diff.page.revert.oneTitle", defaultValue: "Revert changes to %@?", table: "DiffPage", bundle: .l10n)
    }

    static var revertManyTitle: String {
        String(localized: "diff.page.revert.manyTitle", defaultValue: "Revert changes to %lld files?", table: "DiffPage", bundle: .l10n)
    }

    static var revertUnstagedLine: String {
        String(localized: "diff.page.revert.unstagedLine", defaultValue: "Unstaged changes are lost. Staged changes stay.",
               table: "DiffPage", bundle: .l10n)
    }

    static var revertUncommittedLine: String {
        String(localized: "diff.page.revert.uncommittedLine", defaultValue: "Staged and unstaged changes are lost.",
               table: "DiffPage", bundle: .l10n)
    }

    static var revertTrashLine: String {
        String(localized: "diff.page.revert.trashLine", defaultValue: "New files go to the Trash.", table: "DiffPage", bundle: .l10n)
    }

    static var revertButton: String {
        String(localized: "diff.page.revert.button", defaultValue: "Revert", table: "DiffPage", bundle: .l10n)
    }

    static var revertNeedsGesture: String {
        String(localized: "diff.page.revert.needsGesture", defaultValue: "Revert needs a click or key press in the tab.",
               table: "DiffPage", bundle: .l10n)
    }

    static var revertUndoGone: String {
        String(localized: "diff.page.revert.undoGone", defaultValue: "That change can no longer be put back.",
               table: "DiffPage", bundle: .l10n)
    }

    static var revertAndMore: String {
        String(localized: "diff.page.revert.andMore", defaultValue: "and %lld more", table: "DiffPage", bundle: .l10n)
    }

    static var revertBusy: String {
        String(localized: "diff.page.revert.busy", defaultValue: "Another revert is still running.", table: "DiffPage", bundle: .l10n)
    }
}
