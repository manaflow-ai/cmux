public import CmuxAcpmux
public import CmuxConversation
import CmuxMobileShellModel
public import CMUXMobileCore
import Foundation

/// Opens one agent-GUI lane to the foreground Mac: the control lane or a
/// transfer lane, as a byte stream for the acpmux backend.
public typealias MobileAgentLaneOpener = @Sendable (CmxByteTransportRequest, ConversationStreamPurpose) async throws -> any ConversationByteStream

/// The capability a Mac advertises when it relays the agent GUI's lanes.
public let mobileAgentLaneCapability = "acpmux_lane.v1"

@MainActor
extension MobileShellComposite {
    /// Called once by the composition root.
    public func configureAgentLane(_ open: @escaping MobileAgentLaneOpener) {
        agentLaneOpen = open
        syncAgentBackend()
    }

    /// The foreground Mac, when it is connected over Iroh and relays acpmux.
    var agentLaneTarget: String? {
        guard agentLaneOpen != nil, connectionState == .connected,
              supportedHostCapabilities.contains(mobileAgentLaneCapability),
              let activeTicket, let activeRoute, activeRoute.kind == .iroh else { return nil }
        return activeTicket.macDeviceID
    }

    /// Creates or drops the agent backend as the foreground Mac changes.
    /// Idempotent; runs on every connection-state and capability change. A
    /// brief disconnect keeps the backend (it reconnects on its own).
    func syncAgentBackend() {
        guard let open = agentLaneOpen else { return }
        if let target = agentLaneTarget {
            guard agentBackendMacDeviceID != target else { return }
            let old = agentBackend
            Task { await old?.shutdown() }
            let opener = MobileAgentStreamOpener { [weak self] purpose in
                guard let self, let request = await self.agentLaneRequest(macDeviceID: target) else {
                    throw ConversationBackendError.unreachable("the Mac is not connected")
                }
                return try await open(request, purpose)
            }
            // One stream, one session at a time on the phone.
            agentBackend = AcpmuxBackend(opener: opener, clientName: "cmux-ios", singleAttachment: true)
            agentBackendMacDeviceID = target
        } else if let current = agentBackendMacDeviceID, activeTicket?.macDeviceID != current {
            let old = agentBackend
            Task { await old?.shutdown() }
            agentBackend = nil
            agentBackendMacDeviceID = nil
        }
    }

    /// A feature-lane request to the foreground Mac for the agent lanes.
    func agentLaneRequest(macDeviceID: String) -> CmxByteTransportRequest? {
        guard agentLaneTarget == macDeviceID, let activeTicket, let activeRoute else { return nil }
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
}

/// A ``ConversationStreamOpening`` over the shell's agent lanes.
struct MobileAgentStreamOpener: ConversationStreamOpening {
    let openLane: @Sendable (ConversationStreamPurpose) async throws -> any ConversationByteStream

    func open(_ purpose: ConversationStreamPurpose) async throws -> any ConversationByteStream {
        try await openLane(purpose)
    }
}
