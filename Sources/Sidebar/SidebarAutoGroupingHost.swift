import Foundation

/// The machine a workspace runs on, as the Host grouping sees it.
enum SidebarAutoGroupingHost: Equatable, Sendable {
    /// Terminals on this Mac.
    case local
    /// A `cmux ssh` workspace or remote tmux mirror. `target` is the display
    /// target (`user@host`, `host` or `host:port`); the grouping drops `user@`.
    case remote(target: String)
    /// A managed Cloud VM. `label` is the best human name known, if any.
    case cloud(vmID: String, label: String?)

    /// Section key shared by every workspace on the same machine.
    var sectionKey: String {
        switch self {
        case .local:
            return "host:local"
        case .remote(let target):
            return "host:remote:\(Self.hostName(fromTarget: target).lowercased())"
        case .cloud(let vmID, _):
            return "host:cloud:\(vmID)"
        }
    }

    /// Strips a leading `user@` so one host with several logins is one section.
    static func hostName(fromTarget target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed }
        let host = trimmed[trimmed.index(after: at)...]
        return host.isEmpty ? trimmed : String(host)
    }
}
