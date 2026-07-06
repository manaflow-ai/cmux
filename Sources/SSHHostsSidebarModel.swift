import AppKit
import CmuxFoundation
import Observation

/// Backing model for the sidebar's SSH Hosts section: the concrete host
/// aliases scanned from `~/.ssh/config` (following `Include` directives) plus
/// the section's collapse state.
///
/// The alias list refreshes from real signals only — model creation (sidebar
/// mount) and app activation (returning to cmux after editing the config
/// elsewhere) — never from a timer. Scanning runs off the main actor; the
/// published list updates only when the result actually changes, so idle
/// activations don't invalidate the sidebar.
@MainActor
@Observable
final class SSHHostsSidebarModel {
    private(set) var hostAliases: [String] = []
    var isCollapsed = false
    /// Bumped when any workspace's remote connection state transitions, so the
    /// section's per-host active markers re-derive. TabManager churn covers
    /// workspace add/remove/select but not per-workspace state changes.
    private(set) var remoteStateRevision: UInt64 = 0

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var appActivationTask: Task<Void, Never>?
    @ObservationIgnored private var remoteStateTask: Task<Void, Never>?

    init() {
        refresh()
        appActivationTask = Task { [weak self] in
            let activations = NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            )
            for await _ in activations {
                self?.refresh()
            }
        }
        remoteStateTask = Task { [weak self] in
            let transitions = NotificationCenter.default.notifications(
                named: .workspaceRemoteConnectionStateDidChange
            )
            for await _ in transitions {
                self?.remoteStateRevision &+= 1
            }
        }
    }

    deinit {
        appActivationTask?.cancel()
        remoteStateTask?.cancel()
        refreshTask?.cancel()
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
