extension CMUXCLI {
    enum DiffViewerShortcutAction: String, CaseIterable {
        case scrollDown = "diffViewerScrollDown"
        case scrollUp = "diffViewerScrollUp"
        case scrollHalfPageDown = "diffViewerScrollHalfPageDown"
        case scrollHalfPageUp = "diffViewerScrollHalfPageUp"
        case scrollDownEmacs = "diffViewerScrollDownEmacs"
        case scrollUpEmacs = "diffViewerScrollUpEmacs"
        case scrollToBottom = "diffViewerScrollToBottom"
        case scrollToTop = "diffViewerScrollToTop"
        case openFileSearch = "diffViewerOpenFileSearch"
        case nextFile = "diffViewerNextFile"
        case previousFile = "diffViewerPreviousFile"

        var defaultShortcut: DiffViewerShortcut {
            switch self {
            case .scrollDown:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "j"))
            case .scrollUp:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "k"))
            case .scrollHalfPageDown:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "d", control: true))
            case .scrollHalfPageUp:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "u", control: true))
            case .scrollDownEmacs:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "n", control: true))
            case .scrollUpEmacs:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "p", control: true))
            case .scrollToBottom:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "g", shift: true))
            case .scrollToTop:
                return DiffViewerShortcut(
                    first: DiffViewerShortcutStroke(key: "g"),
                    second: DiffViewerShortcutStroke(key: "g")
                )
            case .openFileSearch:
                return DiffViewerShortcut(first: DiffViewerShortcutStroke(key: "/"))
            case .nextFile:
                return DiffViewerShortcut(
                    first: DiffViewerShortcutStroke(key: "]"),
                    second: DiffViewerShortcutStroke(key: "f")
                )
            case .previousFile:
                return DiffViewerShortcut(
                    first: DiffViewerShortcutStroke(key: "["),
                    second: DiffViewerShortcutStroke(key: "f")
                )
            }
        }
    }

}
