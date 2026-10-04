import CmuxNextBrowser
import Foundation

/// Stub (plans/cmux-next/passwords.md, section 3.4); the request lands next.
enum AgentBrowserProfile {
    enum Request: Equatable {
        case cascade
        case explicit(String)
        case agent
    }

    static let id = ""

    static func request(_ raw: String?) -> Request? { .cascade }
}
