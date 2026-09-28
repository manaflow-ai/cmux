import CmuxCloud
import Foundation

/// One row of a Cloud menu, described once and rendered by both the status
/// item (AppKit) and the main-menu Cloud menu (SwiftUI). The machine verbs in
/// the Cloud sidebar's context menu come from the same builder, so every menu
/// that offers a machine's verbs offers the same ones.
enum CloudMenuEntry: Identifiable {
    case action(CloudMenuAction)
    /// A disabled informational row (account line, section title, status).
    case header(id: String, title: String)
    case submenu(CloudMenuSubmenu)
    case separator(id: String)

    var id: String {
        switch self {
        case .action(let action): return action.id
        case .header(let id, _): return id
        case .submenu(let submenu): return submenu.id
        case .separator(let id): return id
        }
    }
}

struct CloudMenuAction {
    let id: String
    let title: String
    var isEnabled = true
    var isChecked = false
    /// Shown by the status item; the main menu leaves shortcuts to File.
    var shortcut: KeyboardShortcutSettings.Action?
    let perform: @MainActor () -> Void
}

struct CloudMenuSubmenu {
    let id: String
    let title: String
    /// Secondary text after the title (machine status). The status item draws
    /// it dimmed; the main menu appends it with a middle dot.
    var detail: String?
    var tone: CloudMenuTone?
    let children: [CloudMenuEntry]
}

/// Machine health, drawn as a colored dot in the status item.
enum CloudMenuTone: Equatable {
    case ready
    case pending
    case attention
    case locked

    init(_ machine: MachineSnapshot) {
        if machine.freeAccess == .expired { self = .locked; return }
        switch machine.activity {
        case .ready: self = .ready
        case .pending: self = .pending
        case .attention: self = .attention
        }
    }
}
