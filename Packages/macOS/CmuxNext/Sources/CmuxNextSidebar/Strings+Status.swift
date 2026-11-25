import Foundation

extension Strings {
    /// Group by Status's header names (`SidebarStatusSection`): the Priority view's own words for its states.
    static func statusSection(_ section: SidebarStatusSection) -> String {
        switch section {
        case .needsYou: priorityNeedsYou
        case .done: priorityDone
        case .failed: priorityFailed
        case .ciFailing: priorityCIFailing
        case .working: priorityWorking
        case .idle: priorityIdle
        }
    }
}
