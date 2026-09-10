import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Failures the Mac pairing UI can present without exposing transport credentials.
public enum HivePairingError: Error, Equatable, Sendable {
    /// The entry is neither a supported pairing URL nor an explicit IP and port.
    case invalidInput
    /// The entered code identifies a different signed-in account.
    case accountMismatch
    /// The entry has no supported, explicitly authorized Tailscale destination.
    case tailscaleRequired
    /// The authenticated host did not supply a complete app-instance identity.
    case missingIdentity
    /// The authenticated host differs from the identity named by the entered code.
    case identityMismatch
    /// The entry addresses the client's own app instance.
    case thisMac
    /// Another pairing mutation is still running.
    case busy
    /// The captured account session no longer owns the controller.
    case stopped
    /// The local paired-device database could not complete the operation.
    case storageFailed
}

struct HivePairingRequest: Sendable {
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    let authorization: CmxUserTailscalePairingAuthorization?
    let expectedDeviceID: String?

    init(input: String, userID: String, email: String?, allowsLoopback: Bool) throws {
        guard let input = HivePairingInput(input) else { throw HivePairingError.invalidInput }
        let routes: [CmxAttachRoute]
        switch input {
        case .link(let value):
            let decoded = try CmxAttachTicketInput.decode(value)
            if let owner = decoded.macUserID, owner != userID { throw HivePairingError.accountMismatch }
            if let ownerEmail = decoded.macUserEmail, let email,
               ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
                email.trimmingCharacters(in: .whitespacesAndNewlines)
               ) != .orderedSame { throw HivePairingError.accountMismatch }
            routes = decoded.routes
            expectedDeviceID = decoded.macDeviceID.isEmpty ? nil : cmxCanonicalDeviceID(decoded.macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines))
        case .manual(let entry):
            let endpoint = CmxAttachEndpoint.hostPort(host: entry.host, port: entry.port)
            let candidate = try CmxAttachRoute(id: "tailscale", kind: .tailscale, endpoint: endpoint)
            let isLoopback = CmxLoopbackHost().matches(candidate)
            routes = [try CmxAttachRoute(
                id: isLoopback ? "debug_loopback" : "tailscale",
                kind: isLoopback ? .debugLoopback : .tailscale, endpoint: endpoint
            )]
            expectedDeviceID = nil
        }
        let candidates = routes.sorted {
            $0.priority == $1.priority ? $0.id < $1.id : $0.priority < $1.priority
        }
        guard let route = candidates.first(where: { candidate in
            if candidate.kind == .tailscale, case let .hostPort(host, port) = candidate.endpoint {
                return (try? CmxUserTailscalePairingAuthorization(host: host, port: port)) != nil
            }
            return allowsLoopback && candidate.kind == .debugLoopback && CmxLoopbackHost().matches(candidate)
        }) else { throw HivePairingError.tailscaleRequired }
        self.route = route
        if route.kind == .tailscale, case let .hostPort(host, port) = route.endpoint {
            authorization = try CmxUserTailscalePairingAuthorization(host: host, port: port)
        } else {
            authorization = nil
        }
        ticket = try CmxAttachTicket(
            workspaceID: "", terminalID: nil,
            macDeviceID: expectedDeviceID ?? "manual-ticket-request",
            macDisplayName: nil, routes: [route]
        )
    }

    func verifiedIdentity(
        status: MobileHostStatusResponse, ownDeviceID: String, ownInstanceTag: String
    ) throws -> CmxMacAppInstanceIdentity {
        guard let deviceID = status.macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty,
              let tag = status.macInstanceTag?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tag.isEmpty else { throw HivePairingError.missingIdentity }
        if let expectedDeviceID, cmxCanonicalDeviceID(deviceID) != expectedDeviceID {
            throw HivePairingError.identityMismatch
        }
        let identity = CmxMacAppInstanceIdentity(macDeviceID: deviceID, instanceTag: tag)
        guard identity != CmxMacAppInstanceIdentity(macDeviceID: ownDeviceID.trimmingCharacters(in: .whitespacesAndNewlines), instanceTag: ownInstanceTag) else {
            throw HivePairingError.thisMac
        }
        return identity
    }
}
