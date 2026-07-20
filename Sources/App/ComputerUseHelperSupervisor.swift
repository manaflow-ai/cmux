import Foundation

/// Restarts the Computer Use helper after an unexpected termination while the feature is enabled.
@MainActor
final class ComputerUseHelperSupervisor {
    private let helperAppURL: URL
    private let helperBundleIdentifier: String?
    private let restart: @MainActor () async -> Void
    private var isEnabled = false
    private var launchedProcessIdentifiers: Set<pid_t> = []

    init(
        helperAppURL: URL,
        helperBundleIdentifier: String?,
        restart: @escaping @MainActor () async -> Void
    ) {
        self.helperAppURL = helperAppURL.resolvingSymlinksInPath().standardizedFileURL
        self.helperBundleIdentifier = helperBundleIdentifier
        self.restart = restart
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            launchedProcessIdentifiers.removeAll()
        }
    }

    func helperDidLaunch(
        bundleURL: URL?,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) {
        guard matchesHelper(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier) else { return }
        launchedProcessIdentifiers.insert(processIdentifier)
    }

    func helperDidTerminate(
        bundleURL: URL?,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) async {
        let wasLaunchedProcess = launchedProcessIdentifiers.remove(processIdentifier) != nil
        guard isEnabled else { return }
        let matchesHelperIdentity = matchesHelper(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        )
        let hasNoReportedIdentity = bundleURL == nil && bundleIdentifier == nil
        guard matchesHelperIdentity || (hasNoReportedIdentity && wasLaunchedProcess) else {
            return
        }
        await restart()
    }

    private func matchesHelper(bundleURL: URL?, bundleIdentifier: String?) -> Bool {
        if let bundleURL {
            return bundleURL.resolvingSymlinksInPath().standardizedFileURL == helperAppURL
        }
        guard let helperBundleIdentifier else { return false }
        return bundleIdentifier == helperBundleIdentifier
    }
}
