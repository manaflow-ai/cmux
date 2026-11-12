import AppKit
package import Foundation
package import Observation

/// The session vault: past agent sessions (Claude Code, Codex, …) of every
/// connected machine, newest first, with the one the person picked. The vault
/// page (`cmux://vault`, Open Vault as Pane) and the right sidebar's Vault
/// section show it; the `vault*` actions act on `selection` unless their
/// invocation names a `session`.
@MainActor
@Observable
package final class SessionVault {
    /// Every session the source knows, as row snapshots.
    package private(set) var rows: [VaultRow] = []
    /// The picked row's id (`VaultRow.id`, a qualified session id).
    package var selection: String?
    /// The list's search text.
    package var filter = ""
    /// The reads of the list: one per reload, and again while a list that is not complete shows on screen.
    @ObservationIgnored package let reads = VaultListReads()
    /// The first read of a reload is running.
    package var isLoading: Bool { reads.isLoading }
    /// The list is not complete yet: the rows are the sessions read so far.
    package var isPartial: Bool { reads.isPartial }
    /// The source's list is the whole list: a session that the source does not have does not exist.
    package var holdsWholeList: Bool { source.isComplete }
    @ObservationIgnored private let source: any VaultSessionSource
    @ObservationIgnored package let pullRequests: VaultPullRequests
    @ObservationIgnored package let copyText: @MainActor (String) -> Void
    @ObservationIgnored package let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let title: @MainActor (AgentSession) -> String

    /// - Parameters:
    ///   - source: The sessions (`AgentHistorySource` in the app).
    ///   - copyText: Puts Copy Resume Command's text on the pasteboard (tests record it: they run
    ///     without a pasteboard server).
    ///   - openURL: Opens a session's pull request (the app's link router).
    ///   - title: A row's title, "Claude Code in cmux" (the app's localized string).
    package init(source: any VaultSessionSource, pullRequests: VaultPullRequests = VaultPullRequests(),
                 copyText: @escaping @MainActor (String) -> Void, openURL: @escaping @MainActor (URL) -> Void,
                 title: @escaping @MainActor (AgentSession) -> String) {
        self.source = source
        self.pullRequests = pullRequests
        self.copyText = copyText
        self.openURL = openURL
        self.title = title
    }

    /// The rows the search keeps.
    package var shownRows: [VaultRow] { rows.filter { $0.matches(filter) } }

    /// Reads new sessions, then rebuilds the rows (a gone selection is cleared). ``VaultListReads`` says
    /// when a list that is not complete is read again.
    package func reload() async {
        await reads.reload(source) { rebuild() }
    }

    /// Rebuilds the rows from what the source already holds.
    package func rebuild() {
        rows = source.sessions().map { VaultRow(session: $0, isLive: source.isLive($0), title: title($0)) }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// The session `id` names (a qualified id or the provider's own id), else the selected one.
    package func session(_ id: String?) -> AgentSession? {
        if let id, !id.isEmpty {
            return rows.first { $0.id == id || $0.session.sessionID == id }?.session
                ?? source.sessions().first { $0.qualifiedID == id || $0.sessionID == id }
        }
        guard let selection else { return nil }
        return rows.first { $0.id == selection }?.session
    }

    /// Whether `session`'s agent still runs in a tab.
    package func isLive(_ session: AgentSession) -> Bool { source.isLive(session) }

    /// Puts `text` on the pasteboard.
    package func copy(_ text: String) { copyText(text) }

    /// The app's copy: `text` as the general pasteboard's only string.
    package static func writeGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
