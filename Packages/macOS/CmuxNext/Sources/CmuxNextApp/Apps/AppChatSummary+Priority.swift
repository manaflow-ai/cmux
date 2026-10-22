import CmuxNextApps
import CmuxNextSidebar

extension AppChatSummary {
    /// A Priority view row as `chat.list` reports it to apps (the row's state names its tier).
    init(priority entry: SidebarPriorityEntry) {
        let state: State = switch entry.state {
        case .needsYou: .needsYou
        case .done: .done
        case .failed: .failed
        case .lost: .lost
        case .ciFailing: .ciFailing
        case .working: .working
        case .idle: .idle
        }
        self.init(id: entry.id, title: entry.title, project: entry.project, machine: entry.machine,
                  state: state, unread: entry.unread, pinned: entry.pinned)
    }
}
