import CmuxHive
import CmuxSettings
import CmuxSettingsUI
import Foundation

/// Computers-section host bridge: maps the hive computers directory
/// (registry + pairings + presence) into the settings package's value
/// snapshots and routes the pane's actions back to it.
extension HostSettingsActions {
    private var computersDirectory: HiveComputerDirectory? {
        HiveComputersService.shared.directory
    }

    func computersSnapshot() -> ComputersSettingsSnapshot? {
        guard let directory = computersDirectory else { return nil }
        return Self.computersSnapshot(
            computers: directory.computers,
            isSignedIn: HiveComputersService.shared.isSignedIn,
            lastRefreshFailed: directory.lastRefreshFailed
        )
    }

    func computersUpdates() -> AsyncStream<ComputersSettingsSnapshot> {
        guard let directory = computersDirectory else {
            return AsyncStream { $0.finish() }
        }
        let source = directory.updates()
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await computers in source {
                    continuation.yield(Self.computersSnapshot(
                        computers: computers,
                        isSignedIn: HiveComputersService.shared.isSignedIn,
                        lastRefreshFailed: directory.lastRefreshFailed
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func refreshComputers() {
        guard let directory = computersDirectory else { return }
        Task { @MainActor in
            await directory.refresh()
        }
    }

    func pairComputer(deviceID: String) async -> ComputersPairResult {
        guard let directory = computersDirectory else { return .failed }
        return Self.pairResult(await directory.pair(deviceID: deviceID))
    }

    func pairComputer(code: String) async -> ComputersPairResult {
        guard let directory = computersDirectory else { return .failed }
        return Self.pairResult(await directory.pair(code: code))
    }

    func unpairComputer(deviceID: String) async {
        guard let directory = computersDirectory else { return }
        await directory.unpair(deviceID: deviceID)
        await HiveComputersService.shared.discardEmbeddedSession(deviceID: deviceID)
    }

    func openComputerViewer(deviceID: String) {
        // One shared action path with the sidebar scope picker and the
        // `hive.open` RPC; honors the `computers.presentation` setting.
        HiveComputerMirrorController.presentViewer(deviceID: deviceID)
    }

    /// Mints a short-lived 6-digit pairing code and advertises it through the
    /// device registry (alongside this Mac's live routes), so another Mac can
    /// pair by typing the code — nothing to copy between machines.
    ///
    /// The listener is brought up first so the registration carries dialable
    /// routes for the claiming Mac to persist.
    func mintComputerPairingCode() async -> ComputersPairingCodeMintResult {
        guard let coordinator = AppDelegate.shared?.auth?.coordinator else { return .failed }
        await coordinator.awaitBootstrapped()
        guard coordinator.isAuthenticated else { return .signedOut }
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        let host = MobileHostService.shared
        let status = await host.ensureListeningAndReady()
        guard status.isRunning else { return .failed }
        guard !status.routes.isEmpty else { return .needsTailscale }
        guard let minted = await DeviceRegistryClient.shared.publishPairingCode(
            routes: status.routes
        ) else { return .failed }
        return .minted(code: minted.code, expiresAt: minted.expiresAt)
    }

    // MARK: - Mapping (pure)

    /// Map the merged directory rows into the settings package's snapshot.
    static func computersSnapshot(
        computers: [HiveComputer],
        isSignedIn: Bool,
        lastRefreshFailed: Bool
    ) -> ComputersSettingsSnapshot {
        ComputersSettingsSnapshot(
            isSignedIn: isSignedIn,
            computers: computers.map(Self.computerRow),
            lastRefreshFailed: lastRefreshFailed
        )
    }

    static func computerRow(_ computer: HiveComputer) -> ComputersSettingsComputer {
        ComputersSettingsComputer(
            deviceID: computer.deviceID,
            name: computer.displayName,
            symbolName: Self.symbolName(forPlatform: computer.platform),
            isThisMac: computer.isThisComputer,
            isPaired: computer.isPaired,
            canPair: !computer.isThisComputer && computer.isPairableHost && !computer.isPaired
                && computer.bestPairingRoutes != nil,
            presence: Self.presence(computer.presence),
            detail: Self.detail(for: computer)
        )
    }

    static func pairResult(_ outcome: HivePairOutcome) -> ComputersPairResult {
        switch outcome {
        case .paired: return .paired
        case .invalidLink: return .invalidLink
        case .codeNotFound: return .codeNotFound
        case .loopbackRejected: return .loopbackRejected
        case .accountMismatch: return .accountMismatch
        case .noRoutes: return .noRoutes
        case .storeFailed: return .failed
        }
    }

    private static func symbolName(forPlatform platform: String?) -> String {
        switch (platform ?? "mac").lowercased() {
        case "ios": return "iphone"
        case "linux", "windows": return "server.rack"
        default: return "desktopcomputer"
        }
    }

    private static func presence(_ presence: HiveComputerPresence) -> ComputersSettingsComputer.Presence {
        switch presence {
        case .online: return .online
        case .offline(let lastSeenAt): return .offline(lastSeenAt: lastSeenAt)
        case .unknown(let lastSeenAt): return .unknown(lastSeenAt: lastSeenAt)
        }
    }

    /// Secondary row line: the presence build label when known, else the
    /// build tag of the freshest route-advertising instance (skipping the
    /// unremarkable stable tags).
    private static func detail(for computer: HiveComputer) -> String? {
        if let label = computer.buildLabel, !label.isEmpty { return label }
        guard let tag = computer.bestPairingRoutes?.instanceTag,
              !["default", "stable"].contains(tag.lowercased()) else { return nil }
        return tag
    }
}
