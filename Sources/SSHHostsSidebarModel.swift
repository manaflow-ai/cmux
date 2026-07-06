import AppKit
import CmuxFoundation
import Observation

/// Backing model for the sidebar's SSH Hosts section: the concrete host
/// aliases scanned from `~/.ssh/config` (following `Include` directives) plus
/// the section's collapse state.
///
/// Creating the model has no side effects — SwiftUI evaluates `@State`
/// initial values for throwaway view inits, so all scanning/observation runs
/// inside ``run()`` under the mount's `.task`. The alias list refreshes from
/// real signals only — mount and app activation (returning to cmux after
/// editing the config elsewhere) — never from a timer. Scanning runs off the
/// main actor; the published list updates only when the result actually
/// changes, so idle activations don't invalidate the sidebar.
@MainActor
@Observable
final class SSHHostsSidebarModel {
    private(set) var hostAliases: [String] = []
    var isCollapsed = false
    /// Bumped when a listed host's workspace remote connection state
    /// transitions, so the section's per-host active markers re-derive.
    /// TabManager churn covers workspace add/remove/select but not
    /// per-workspace state changes.
    private(set) var remoteStateRevision: UInt64 = 0

    /// Aliases with a `cmux ssh` launch in flight: set when the bundled CLI
    /// spawns and cleared when it exits (the CLI returns only after
    /// workspace.create/configure/select complete), so rapid re-clicks cannot
    /// spawn duplicate workspaces for one host.
    private(set) var pendingConnectAliases: Set<String> = []

    /// O(1) relevance filter for remote-state notifications; mirrors
    /// `hostAliases`.
    @ObservationIgnored private var hostAliasLookup: Set<String> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    deinit {
        refreshTask?.cancel()
    }

    /// Drives the model while its sidebar anchor is mounted: scans once, then
    /// refreshes on app activation and folds workspace remote-state
    /// transitions into ``remoteStateRevision``. Structured under the caller's
    /// `.task`, so unmounting (or toggling the setting off) cancels both
    /// observation streams.
    func run() async {
        refresh()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                let activations = NotificationCenter.default.notifications(
                    named: NSApplication.didBecomeActiveNotification
                )
                for await _ in activations {
                    self?.refresh()
                }
            }
            group.addTask { @MainActor [weak self] in
                let transitions = NotificationCenter.default.notifications(
                    named: .workspaceRemoteConnectionStateDidChange
                )
                for await notification in transitions {
                    guard let self else { return }
                    // Only a listed alias's transition can change a row
                    // marker; ignoring VM/user@host remotes keeps reconnect
                    // storms from re-running sidebar bodies for nothing.
                    guard let workspace = notification.object as? Workspace,
                          let destination = workspace.remoteConfiguration?.destination,
                          self.hostAliasLookup.contains(destination) else {
                        continue
                    }
                    self.remoteStateRevision &+= 1
                }
            }
        }
    }

    /// Claims a pending connect slot for `alias`.
    /// - Returns: `false` when a launch for that alias is already in flight
    ///   (the caller should ignore the click).
    func beginPendingConnect(alias: String) -> Bool {
        pendingConnectAliases.insert(alias).inserted
    }

    /// Releases the pending connect slot for `alias`.
    func endPendingConnect(alias: String) {
        pendingConnectAliases.remove(alias)
    }

    /// Rescans the SSH config. Coalesces: a refresh requested while one is
    /// already in flight is dropped (the scan is fast and re-triggered by the
    /// next real signal).
    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let aliases = await Self.scanHostAliases()
            guard let self else { return }
            self.refreshTask = nil
            self.hostAliasLookup = Set(aliases)
            if self.hostAliases != aliases {
                self.hostAliases = aliases
            }
        }
    }

    /// Scans `~/.ssh/config` off the main actor and returns the aliases
    /// sorted for display.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func scanHostAliases() async -> [String] {
        let scanner = SSHConfigHostAliasScanner(homeDirectory: NSHomeDirectory())
        return scanner.hostAliases(inConfigAtPath: scanner.defaultUserConfigPath)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
