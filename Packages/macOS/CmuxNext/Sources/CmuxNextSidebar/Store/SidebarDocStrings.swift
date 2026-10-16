import Foundation

/// Localized strings of the sidebar document path (Resources/Localizable.xcstrings).
enum SidebarDocStrings {
    static var unavailable: String {
        String(localized: "sidebar.doc.unavailable", defaultValue: "The sidebar cannot move items right now.", bundle: .module)
    }

    static var move: String { String(localized: "sidebar.doc.move", defaultValue: "Move", bundle: .module) }

    /// A refusal code from the reducer (`cross_machine`, `provider_owned`, ...).
    static func refused(_ code: String) -> String {
        switch code {
        case "cross_machine":
            String(localized: "sidebar.doc.refused.crossMachine", defaultValue: "Workspaces stay on their machine.", bundle: .module)
        case "provider_owned":
            String(localized: "sidebar.doc.refused.providerOwned", defaultValue: "An app fills this section.", bundle: .module)
        default:
            String(localized: "sidebar.doc.refused.other", defaultValue: "The sidebar did not make this move.", bundle: .module)
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? SidebarMirror.Refusal).map { refused($0.code) } ?? refused("")
    }
}

extension SidebarDocStore {
    /// The undo title of a drag or keyboard move.
    public static var moveTitle: String { SidebarDocStrings.move }
}
