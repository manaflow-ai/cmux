import Foundation

/// The diff viewer host's strings (table `DiffPage`). The page's own labels
/// ship with the page (webviews/src/labels.ts, English and Japanese).
nonisolated enum DiffPageStrings {
    static var tabTitle: String {
        String(localized: "diff.page.tabTitle", defaultValue: "Diff", table: "DiffPage", bundle: .module)
    }

    static var notRepository: String {
        String(localized: "diff.page.notRepository", defaultValue: "This folder is not in a git repository.",
               table: "DiffPage", bundle: .module)
    }

    static var unavailable: String {
        String(localized: "diff.page.unavailable", defaultValue: "The diff viewer is not available in this build.",
               table: "DiffPage", bundle: .module)
    }

    static var noFolder: String {
        String(localized: "diff.page.noFolder", defaultValue: "The focused pane has no folder to diff.",
               table: "DiffPage", bundle: .module)
    }

    static var noDiffTab: String {
        String(localized: "diff.page.noDiffTab", defaultValue: "No diff viewer has the keyboard.",
               table: "DiffPage", bundle: .module)
    }

    static var chooseFolder: String {
        String(localized: "diff.page.chooseFolder", defaultValue: "Choose a folder to diff", table: "DiffPage", bundle: .module)
    }

    static var chooseButton: String {
        String(localized: "diff.page.chooseButton", defaultValue: "Open Diff", table: "DiffPage", bundle: .module)
    }
}
