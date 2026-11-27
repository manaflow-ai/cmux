import Foundation

/// Which agent chat opened each file, so a quote from the file's viewer goes back to that chat.
/// In memory only: a relaunch forgets it and quotes go to Chief (viewer-comments-DESIGN.md).
@MainActor
final class ChatQuoteOpeners {
    private var openers: [String: String] = [:]

    /// Agent chat tab `tab` opened `file`; a later opener replaces an earlier one.
    func noteOpened(_ file: URL, byAgentTab tab: String) {
        openers[Self.key(file.path)] = tab
    }

    /// The chat a quote from `source` (a file path) goes to: its opener while `isLive` says the
    /// opener's tab still has a chat that can take it, else Chief.
    func target(for source: String, isLive: (String) -> Bool) -> ChatQuoteTarget {
        guard let tab = openers[Self.key(source)], isLive(tab) else { return .chief }
        return .agentTab(tab)
    }

    /// One key per file however it was named (symlinks, `..`).
    static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
