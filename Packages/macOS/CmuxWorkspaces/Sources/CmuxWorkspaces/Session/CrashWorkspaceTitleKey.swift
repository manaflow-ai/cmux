import Foundation

/// Stable title, description, and directory identity used for legacy workspace matching.
struct CrashWorkspaceTitleKey: Hashable {
    let title: String
    let description: String?
    let directory: String
}
