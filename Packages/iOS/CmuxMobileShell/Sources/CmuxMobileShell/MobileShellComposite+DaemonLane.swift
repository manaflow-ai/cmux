public import CMUXMobileCore
public import CmuxMobileSSH
internal import CryptoKit
internal import CmuxMobileRPC
public import CmuxMobileShellModel
public import Foundation

/// Opens a cmux-tui carrier to a paired Mac's daemon over an irx `daemon`
/// lane (`MobileIrxRuntimeComposition.openDaemonLane`).
public typealias MobileDaemonLaneOpener = @Sendable (CmxByteTransportRequest) async throws -> any CmuxTUICarrier

/// How the phone reaches cmux-next Macs' daemons, supplied by the app.
public struct MobileDaemonLaneConfiguration: Sendable {
    /// ``MobileDaemonLaneFlag/isEnabled`` for this build.
    public var isEnabled: Bool
    public var open: MobileDaemonLaneOpener

    public init(isEnabled: Bool, open: @escaping MobileDaemonLaneOpener) {
        self.isEnabled = isEnabled
        self.open = open
    }
}

/// Daemon-lane workspaces (plans/cmux-next/cloud-ios.md): when this build
/// enables the lane and the foreground Mac advertises `daemon_lane.v1`, the
/// Mac's cmux-tui daemon appears as a lane computer in ``sshComputers``. Its
/// rows list the daemon's own workspaces, and opening a terminal attaches in
/// bytes mode over the lane, exactly like an SSH computer's cmux-tui session.
/// The Mac's mobile.* rows stay as they are, so the default path is unchanged.
@MainActor
extension MobileShellComposite {
    /// Called once by the composition root.
    public func configureDaemonLane(_ configuration: MobileDaemonLaneConfiguration) {
        daemonLane = configuration
        syncDaemonLaneComputer()
    }

    /// Whether the foreground Mac should have a lane computer now.
    var daemonLaneTarget: (macDeviceID: String, name: String)? {
        guard let daemonLane, daemonLane.isEnabled,
              connectionState == .connected,
              supportedHostCapabilities.contains(MobileDaemonLaneFlag.capability),
              let activeTicket, let activeRoute, activeRoute.kind == .iroh else { return nil }
        return (activeTicket.macDeviceID, connectedHostName)
    }

    /// Registers, renames, or removes the foreground Mac's lane computer.
    /// Idempotent; runs on every connection-state and capability change.
    func syncDaemonLaneComputer() {
        let target = daemonLaneTarget
        if let current = daemonLaneComputer, current.macDeviceID != target?.macDeviceID {
            daemonLaneComputer = nil
            let computers = sshComputers
            Task { await computers.removeLaneComputer(id: current.id) }
        }
        guard let target, let daemonLane else { return }
        let id = Self.daemonLaneComputerID(macDeviceID: target.macDeviceID)
        daemonLaneComputer = (id, target.macDeviceID)
        let open = daemonLane.open
        let macDeviceID = target.macDeviceID
        sshComputers.registerLaneComputer(id: id, name: target.name) { [weak self] in
            guard let self, let request = self.daemonLaneRequest(macDeviceID: macDeviceID) else {
                throw MobileTunnelOpenFailure.unavailable
            }
            return try await open(request)
        }
        startDaemonLaneDogfoodIfRequested(computerID: id)
    }

    /// A feature-lane request to the foreground Mac, pinned to its device id
    /// and to the method's dial candidates like every other irx lane. `nil`
    /// once that Mac is no longer the connected foreground.
    func daemonLaneRequest(macDeviceID: String) -> CmxByteTransportRequest? {
        guard daemonLaneTarget?.macDeviceID == macDeviceID,
              let activeTicket, let activeRoute else { return nil }
        return CmxByteTransportRequest(
            route: activeRoute,
            expectedPeerDeviceID: activeTicket.macDeviceID,
            authorizationMode: .transportAdmission,
            sessionPurpose: .featureLane,
            irohDirectOnlyDialCandidates: irohMethodPinnedDialCandidates(
                forMacDeviceID: activeTicket.macDeviceID,
                instanceTag: activeMacInstanceTag
            )
        )
    }

    /// A stable lane-computer id per Mac, so row and surface ids survive
    /// reconnects (they embed it) and never collide with a saved SSH host.
    nonisolated static func daemonLaneComputerID(macDeviceID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("cmux-daemon-lane:\(macDeviceID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - DEBUG dogfood driver

/// Agents dogfood the lane in an isolated Simulator without touch input:
/// `CMUX_DAEMON_LANE_DOGFOOD_TYPE=<text>` opens the lane computer's first
/// workspace once it lists and types `text` into its first terminal through
/// the same input path as the keyboard. DEBUG builds only.
@MainActor
extension MobileShellComposite {
    func startDaemonLaneDogfoodIfRequested(computerID: UUID) {
        #if DEBUG
        guard daemonLaneDogfoodInput == nil,
              let text = ProcessInfo.processInfo.environment["CMUX_DAEMON_LANE_DOGFOOD_TYPE"], !text.isEmpty else { return }
        daemonLaneDogfoodInput = (nil, text.replacingOccurrences(of: "\\r", with: "\r"))
        openDaemonLaneDogfoodWorkspaceIfListed()
        #endif
    }

    /// Opens the lane computer's first terminal once its rows are published
    /// (called after every SSH/lane publish while the dogfood text waits).
    func openDaemonLaneDogfoodWorkspaceIfListed() {
        #if DEBUG
        guard let pending = daemonLaneDogfoodInput, pending.surfaceID == nil,
              let computer = daemonLaneComputer else { return }
        let machine = MobileSSHIdentifier(computerOf: computer.id).rawValue
        guard let row = workspaces.first(where: { $0.macDeviceID == machine }),
              let terminal = row.terminals.first else { return }
        daemonLaneDogfoodInput?.surfaceID = terminal.id.rawValue
        // The explicit navigation intent (what a notification tap uses):
        // the compact stack ignores bare selection changes.
        navigateToWorkspaceForDeeplink(row.id)
        selectTerminal(terminal.id)
        #endif
    }

    /// Types the pending dogfood text once the terminal starts attaching: the
    /// first delivery is the attach's own reset, so the text is queued behind
    /// the attach and sent the moment it lands.
    func deliverDaemonLaneDogfoodInputIfAttaching(surfaceID: String) {
        #if DEBUG
        guard let pending = daemonLaneDogfoodInput, pending.surfaceID == surfaceID, !pending.text.isEmpty else { return }
        daemonLaneDogfoodInput = (surfaceID, "")
        sshComputers.input(Data(pending.text.utf8), surfaceID: surfaceID)
        #endif
    }
}
