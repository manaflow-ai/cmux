#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    // MARK: - Ticket + grant surface (gated on `.published`)

    /// Typed refusal for ticket/grant requests. `notReady` names the exact
    /// readiness rung so callers can render "not ready (state)" verbatim.
    enum RequestFailure: Error, CustomStringConvertible {
        case notReady(readiness: NextTransportReadiness, state: String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case .notReady(let readiness, let state):
                return "not ready (\(readiness)); state: \(state)"
            case .encodingFailed(let what):
                return "\(what) did not encode"
            }
        }
    }

    /// The dial ticket an iOS dev build needs: host key + relay, the same
    /// shape the lab's hostd emits. Published through the debug socket
    /// (next_transport_ticket) so tooling can hand it to the phone.
    /// Available ONLY at `.published`: a ticket handed out before the relay
    /// attach and address set are current invites the half-ready dial race
    /// of cmux#9724.
    func mintTicketJSON() -> Result<String, RequestFailure> {
        guard readiness == .published, let endpoint, let signer else {
            MobileHostNextTransportRuntime.logger.notice(
                """
                ticket mint refused: host not published \
                (endpoint=\(self.endpoint != nil, privacy: .public) \
                signer=\(self.signer != nil, privacy: .public) \
                readiness=\(self.readiness.description, privacy: .public) \
                state=\(self.state, privacy: .public))
                """)
            return .failure(.notReady(readiness: readiness, state: state))
        }
        // Real LAN addresses first: bound sockets report the wildcard
        // (0.0.0.0:port), which after a loopback rewrite only a dialer ON
        // this Mac (the simulator lab) can reach. A phone on the same
        // network needs interface IPs carrying the bound port. Loopback
        // stays for the sim flows.
        let bound = endpoint.boundSockets()
        var addrs: [String] = []
        if let v4Port = bound.first(where: { $0.contains(".") })?
            .split(separator: ":").last
        {
            let interfaces =
                (try? CmxIrohSystemLANInterfaceSnapshotProvider().interfaceAddresses()) ?? []
            for interface in interfaces where interface.family == .ipv4 {
                addrs.append("\(interface.ipAddress):\(v4Port)")
            }
        }
        addrs.append(
            contentsOf: bound.map {
                $0.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            })
        var ticket: [String: JSONValue] = [
            "key": .data(endpoint.id().toBytes()),
            "serverKey": .data(signer.publicKeyData),
            "addrs": .array(addrs.map { .string($0) }),
        ]
        if let relayURL { ticket["relay"] = .string(relayURL) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(ticket)),
            let json = String(data: data, encoding: .utf8)
        else {
            MobileHostNextTransportRuntime.logger.error("ticket mint failed: ticket JSON did not encode")
            return .failure(.encodingFailed("ticket JSON"))
        }
        MobileHostNextTransportRuntime.logger.notice(
            """
            ticket minted endpoint=\(String(self.endpointID?.prefix(8) ?? "?"), privacy: .public) \
            addrs=\(addrs.joined(separator: ","), privacy: .public) \
            relay=\(self.relayURL ?? "none", privacy: .public)
            """)
        return .success(json)
    }

    /// Mint a grant for a dialing device (dev flow: the embedded signer
    /// stands in for the pairing broker, exactly as in the lab's hostd).
    /// Gated on `.published` like the ticket: a grant against a host that
    /// is not yet dialable is a paste-flow dead end.
    func mintGrant(
        deviceID: String, devicePublicKey: Data, appIdentity: String
    ) -> Result<String, RequestFailure> {
        guard readiness == .published, let signer else {
            MobileHostNextTransportRuntime.logger.notice(
                """
                grant mint refused: host not published \
                device=\(String(deviceID.prefix(8)), privacy: .public) \
                readiness=\(self.readiness.description, privacy: .public) \
                state=\(self.state, privacy: .public)
                """)
            return .failure(.notReady(readiness: readiness, state: state))
        }
        guard let accountID = MobileHostService.shared.currentAuthenticatedLocalUserIDIfReady(),
            !accountID.isEmpty
        else {
            // Never mint a grant with a placeholder account. A grant issued
            // while signed out would remain cryptographically valid after a
            // later account switch and could cross the host's trust boundary.
            MobileHostNextTransportRuntime.logger.notice(
                "grant mint refused: no authenticated account")
            return .failure(.notReady(readiness: readiness, state: state))
        }
        let issuedAt = Int64(Date().timeIntervalSince1970)
        guard
            let grant = try? signer.mint(
                accountID: accountID, deviceID: deviceID,
                devicePublicKey: devicePublicKey, appIdentity: appIdentity,
                grantID: "g-dev-\(UUID().uuidString.prefix(8))",
                issuedAt: issuedAt,
                expiresAt: issuedAt + Self.grantLifetimeSeconds),
            let data = try? JSONEncoder().encode(JSONValue.object(["grant": grant.payloadValue])),
            let json = String(data: data, encoding: .utf8)
        else {
            MobileHostNextTransportRuntime.logger.error(
                """
                grant mint FAILED device=\(String(deviceID.prefix(8)), privacy: .public) \
                app=\(appIdentity, privacy: .public)
                """)
            return .failure(.encodingFailed("grant"))
        }
        issuedGrantIDs.insert(grant.grantID)
        MobileHostNextTransportRuntime.logger.notice(
            """
            grant minted device=\(String(deviceID.prefix(8)), privacy: .public) \
            app=\(appIdentity, privacy: .public) \
            grantID=\(String(grant.grantID.prefix(8)), privacy: .public) \
            key=\(HexEncoding().lowercase(devicePublicKey.prefix(4)), privacy: .public)
            """)
        return .success(json)
    }

    /// Explicitly revokes one issued grant and records the denylist in the
    /// device-only store. This seam is used by future unpair/debug controls;
    /// stop and account transitions revoke all grants issued by this runtime.
    func revokeGrant(id: String) async throws {
        issuedGrantIDs.insert(id)
        if let host {
            await host.revokeGrant(id: id)
        } else {
            try await grantRevocationStore.revoke([id])
        }
        // Surface any persistence failure even when the host closed the live
        // session successfully; an in-memory revoke alone is not durable.
        _ = try await grantRevocationStore.load()
    }

}
#endif
