import AppKit
import CmuxHive
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

    func pairComputerWithLink(_ link: String) async -> ComputersPairResult {
        guard let directory = computersDirectory else { return .failed }
        return Self.pairResult(await directory.pair(link: link))
    }

    func unpairComputer(deviceID: String) async {
        guard let directory = computersDirectory else { return }
        await directory.unpair(deviceID: deviceID)
    }

    func openComputerViewer(deviceID: String) {
        HiveViewerWindowController.shared.show(deviceID: deviceID)
    }

    /// Mints this Mac's attach link (the same payload the pairing window's QR
    /// encodes) and copies it to the clipboard for pasting on another Mac.
    ///
    /// Prefers the Tailscale-only v2 grammar (works across machines). Dev
    /// builds fall back to an all-routes ticket when no Tailscale route
    /// exists, so two tagged builds on one machine can pair over loopback.
    func copyComputerPairingLink() async -> ComputersCopyLinkResult {
        guard let coordinator = AppDelegate.shared?.auth?.coordinator else { return .failed }
        await coordinator.awaitBootstrapped()
        guard coordinator.isAuthenticated else { return .signedOut }
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        let host = MobileHostService.shared
        let status = await host.ensureListeningAndReady()
        guard status.isRunning else { return .failed }
        do {
            return copyLinkToPasteboard(try await host.createAttachTicket(
                workspaceID: "",
                terminalID: nil,
                ttl: 600,
                target: .physicalDevice
            ))
        } catch MobileAttachTicketStoreError.noRoutes,
                MobileAttachTicketStoreError.routeUnavailable,
                MobileAttachTicketStoreError.invalidAttachURL {
            #if DEBUG
            // Same-machine dogfood: no Tailscale route, but the dev loopback
            // route lets a second tagged build on this Mac pair.
            do {
                return copyLinkToPasteboard(try await host.createAttachTicket(
                    workspaceID: "",
                    terminalID: nil,
                    ttl: 600,
                    target: .ticketOnly
                ))
            } catch {
                return .needsTailscale
            }
            #else
            return .needsTailscale
            #endif
        } catch {
            return .failed
        }
    }

    private func copyLinkToPasteboard(_ payload: [String: Any]) -> ComputersCopyLinkResult {
        guard let attachURL = payload["attach_url"] as? String, !attachURL.isEmpty else {
            return .failed
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(attachURL, forType: .string)
        return .copied
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
            canPair: computer.isPairableHost && !computer.isPaired && computer.bestPairingRoutes != nil,
            presence: Self.presence(computer.presence),
            detail: Self.detail(for: computer)
        )
    }

    static func pairResult(_ outcome: HivePairOutcome) -> ComputersPairResult {
        switch outcome {
        case .paired: return .paired
        case .invalidLink: return .invalidLink
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
