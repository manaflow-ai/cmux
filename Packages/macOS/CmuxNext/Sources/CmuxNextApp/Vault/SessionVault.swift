import AppKit
import CmuxNextHistory
import CmuxNextPages
import CmuxNextWakeups
import Observation

/// The session vault: past agent sessions (Claude Code, Codex, …) of every
/// connected machine, newest first, with the one the person picked. The vault
/// page (`cmux://vault`, Open Vault as Pane) and the right sidebar's Vault
/// section show it; the `vault*` actions act on `selection` unless their
/// invocation names a `session`.
@MainActor
@Observable
final class SessionVault {
    /// Every session the source knows, as row snapshots.
    private(set) var rows: [VaultRow] = []
    /// The picked row's id (`VaultRow.id`, a qualified session id).
    var selection: String?
    /// The list's search text.
    var filter = ""
    /// A reload is running.
    private(set) var isLoading = false
    @ObservationIgnored private let source: any VaultSessionSource
    @ObservationIgnored let pullRequests: VaultPullRequests
    @ObservationIgnored let copyText: @MainActor (String) -> Void
    @ObservationIgnored let openURL: @MainActor (URL) -> Void
    /// Where ``startReload()`` runs its read.
    @ObservationIgnored private let work: BackgroundWork

    /// - Parameters:
    ///   - source: The sessions (`AgentHistorySource` in the app).
    ///   - work: The app's background work (``startReload()``'s read).
    ///   - copyText: Puts Copy Resume Command's text on the pasteboard (tests record it: they run
    ///     without a pasteboard server).
    ///   - openURL: Opens a session's pull request (the app's link router).
    init(source: any VaultSessionSource, work: BackgroundWork, pullRequests: VaultPullRequests = VaultPullRequests(),
         copyText: @escaping @MainActor (String) -> Void = SessionVault.writeGeneralPasteboard,
         openURL: @escaping @MainActor (URL) -> Void = { _ = LinkRouter.shared.open($0) }) {
        self.source = source
        self.work = work
        self.pullRequests = pullRequests
        self.copyText = copyText
        self.openURL = openURL
    }

    /// The rows the search keeps.
    var shownRows: [VaultRow] { rows.filter { $0.matches(filter) } }

    /// Reads new sessions, then rebuilds the rows (a gone selection is cleared).
    func reload() async {
        isLoading = true
        await source.refresh()
        rebuild()
        isLoading = false
    }

    /// Starts ``reload()`` without waiting: the person's Refresh and the vault page's reload, at user-blocking
    /// priority (the rest of their click or key).
    func startReload() {
        // task-owner: BackgroundWork (quit skips it); one read, it ends when the rows are rebuilt (recipe R-hop)
        work.task(.userBlocking) { [weak self] in await self?.reload() }
    }

    /// Rebuilds the rows from what the source already holds.
    func rebuild() {
        rows = source.sessions().map {
            VaultRow(session: $0, isLive: source.isLive($0), title: HistoryAppStrings.agentTitle(provider: $0.provider, cwd: $0.cwd))
        }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    /// The session `id` names (a qualified id or the provider's own id), else the selected one.
    func session(_ id: String?) -> AgentSession? {
        if let id, !id.isEmpty {
            return rows.first { $0.id == id || $0.session.sessionID == id }?.session
                ?? source.sessions().first { $0.qualifiedID == id || $0.sessionID == id }
        }
        guard let selection else { return nil }
        return rows.first { $0.id == selection }?.session
    }

    /// Whether `session`'s agent still runs in a tab.
    func isLive(_ session: AgentSession) -> Bool { source.isLive(session) }

    /// Puts `text` on the pasteboard.
    func copy(_ text: String) { copyText(text) }

    /// The app's copy: `text` as the general pasteboard's only string.
    static func writeGeneralPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
