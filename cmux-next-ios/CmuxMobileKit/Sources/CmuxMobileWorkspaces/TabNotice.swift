import Foundation

/// The workspace toast's copy for a tab the Mac would not open or close: one short,
/// plain line. The Mac's own reason (often internal, e.g. "cwd is refused: a remote
/// WebSocket connection may use only a known project or a configured webRoots folder")
/// never reaches the toast; it goes to the log as `detail`.
public struct TabNotice: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Opening a tab: `optionTitle` is the new-tab menu title ("New Claude Chat",
        /// "New Terminal", "New Browser").
        case open(optionTitle: String)
        /// Closing the tab named `title`.
        case close(title: String)
        /// Renaming the tab named `title`.
        case rename(title: String)
        /// Moving the tab named `title`.
        case move(title: String)
        /// A tab group action, by its Mac title ("New Tab Group").
        case group(String)
        /// Another tab action: "Couldn't <verb> <title>."
        case other(verb: String, title: String)
    }

    /// The one line the toast shows.
    public let text: String
    /// The Mac's reason, for the log.
    public let detail: String

    public init(action: Action, macName: String, reason: String) {
        detail = reason
        text = Self.text(action: action, macName: macName, reason: reason)
    }

    /// Why a request failed, from the Mac's or the link's wording.
    enum Cause: Equatable {
        case folderNotAllowed, offline, gone, notAllowed, other
    }

    static func cause(of reason: String) -> Cause {
        let r = reason.lowercased()
        func any(_ words: [String]) -> Bool { words.contains { r.contains($0) } }
        if any(["cwd", "webroots", "known project", "working directory", "folder is not allowed", "outside the allowed"]) { return .folderNotAllowed }
        if any(["offline", "not connected", "disconnected", "no connection", "timed out", "timeout", "unreachable", "link is down", "network connection was lost"]) { return .offline }
        if any(["no longer", "not found", "no such workspace", "unknown workspace", "workspace is gone"]) { return .gone }
        if any(["not_admitted", "not admitted", "unauthorized", "forbidden", "permission denied", "not allowed", "refused"]) { return .notAllowed }
        return .other
    }

    /// "an agent chat" for any agent entry ("New Agent Chat", "New Claude Chat");
    /// "a terminal" style names for the other kinds.
    static func subject(ofOption title: String) -> (isAgent: Bool, thing: String) {
        var name = title
        if name.hasPrefix("New ") { name.removeFirst(4) }
        if name.hasSuffix("…") { name.removeLast() }
        if name.hasSuffix(" Chat") || name.hasPrefix("Agent Chat") { return (true, "an agent chat") }
        return (false, "a \(name.lowercased())")
    }

    static func text(action: Action, macName: String, reason: String) -> String {
        let cause = cause(of: reason)
        switch action {
        case .open(let optionTitle):
            let (isAgent, thing) = subject(ofOption: optionTitle)
            switch cause {
            case .folderNotAllowed:
                // An older Mac, a folder acpmux has not been told of yet, or a symlink out.
                if isAgent { return "\(macName) doesn't allow agent chats in this folder from your iPhone." }
                return "Can't open \(thing) in this folder from your iPhone."
            case .offline: return "Connect to \(macName) first."
            case .gone: return "This workspace is no longer on \(macName)."
            case .notAllowed: return "\(macName) didn't allow \(thing) from your iPhone."
            case .other: return "Couldn't open \(thing) on \(macName)."
            }
        case .group(let actionTitle):
            switch cause {
            case .offline: return "Connect to \(macName) first."
            case .gone: return "This workspace is no longer on \(macName)."
            default: return "\(actionTitle.replacingOccurrences(of: "…", with: "")) didn't work on \(macName)."
            }
        case .close(let title), .rename(let title), .move(let title), .other(_, let title):
            let verb = switch action {
            case .rename: "rename"
            case .move: "move"
            case .other(let verb, _): verb
            default: "close"
            }
            switch cause {
            case .offline: return "Connect to \(macName) first."
            case .gone: return "This workspace is no longer on \(macName)."
            default: return "Couldn't \(verb) \(title)."
            }
        }
    }
}
