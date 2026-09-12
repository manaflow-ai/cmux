import CMUXMobileCore
import CmuxIrohTransport
import CmuxNextTransport
import CryptoKit
import Foundation

extension TerminalController {
    /// Serves `next_transport_ticket`: the parallel host's dial ticket
    /// (key + addrs + relay), or an `ERROR: ` reply naming the readiness
    /// rung that refused it (tickets exist only at `.published`).
    nonisolated func nextTransportTicketText() -> String {
        #if DEBUG
        return v2MainSync {
            switch MobileHostService.shared.nextTransportRuntime.mintTicketJSON() {
            case .success(let ticket):
                return ticket
            case .failure(let failure):
                return "ERROR: " + String(
                    localized: "cli.nextTransport.ticketUnavailable",
                    defaultValue: "Next-transport ticket unavailable: \(failure.description). Enable it in Debug > Next Transport."
                )
            }
        }
        #else
        return "ERROR: " + String(
            localized: "cli.nextTransport.debugOnly",
            defaultValue: "Next transport is available only in a debug build."
        )
        #endif
    }

    /// Serves `next_transport_grant <deviceId> <devicePublicKeyB64> <appIdentity>`.
    nonisolated func nextTransportGrantText(_ args: String) -> String {
        #if DEBUG
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 3, let key = Data(base64Encoded: parts[1]) else {
            return "ERROR: " + String(
                localized: "cli.nextTransport.grantUsage",
                defaultValue: "Usage: cmux next-transport-grant <deviceId> <devicePublicKeyB64> <appIdentity>"
            )
        }
        return v2MainSync {
            switch MobileHostService.shared.nextTransportRuntime.mintGrant(
                deviceID: parts[0], devicePublicKey: key, appIdentity: parts[2])
            {
            case .success(let grant):
                return grant
            case .failure(let failure):
                return "ERROR: " + String(
                    localized: "cli.nextTransport.grantUnavailable",
                    defaultValue: "Next-transport grant unavailable: \(failure.description). Enable it in Debug > Next Transport."
                )
            }
        }
        #else
        return "ERROR: " + String(
            localized: "cli.nextTransport.debugOnly",
            defaultValue: "Next transport is available only in a debug build."
        )
        #endif
    }

    #if DEBUG
    enum NextTransportPairAuthorization: Sendable {
        case localControlSocket
        case mobileRPC(MobileHostRPCExecutionContext)
    }

    /// Serves `mobile.next_transport.pair` (graduation slice 2): the phone
    /// requests its next-transport ticket + grant over the ALREADY
    /// authenticated channel, replacing the dev-screen paste flow. Params
    /// carry the phone's next-transport identity; the grant binds to it.
    @MainActor
    func v2MobileNextTransportPair(
        params: [String: Any],
        authorization: NextTransportPairAuthorization?
    ) -> V2CallResult {
        guard
            let deviceID = params["device_id"] as? String,
            let keyB64 = params["device_public_key"] as? String,
            let key = Data(base64Encoded: keyB64),
            let appIdentity = params["app_identity"] as? String
        else {
            return .err(
                code: "invalid_params",
                message: "device_id, device_public_key (base64), app_identity required",
                data: nil)
        }
        guard Self.nextTransportPairRequesterIsBound(
            deviceID: deviceID,
            deviceKey: key,
            appIdentity: appIdentity,
            proofBase64: params["device_proof"] as? String,
            authorization: authorization
        ) else {
            return .err(
                code: "forbidden",
                message: String(
                    localized: "cli.nextTransport.commandFailed",
                    defaultValue: "Next-transport command failed. Check Debug > Next Transport."
                ),
                data: nil)
        }
        let runtime = MobileHostService.shared.nextTransportRuntime
        guard runtime.isEnabled else {
            return .err(
                code: "unavailable",
                message: "next-transport host disabled (state: \(runtime.state))",
                data: nil)
        }
        let ticket: String
        switch runtime.mintTicketJSON() {
        case .success(let minted):
            ticket = minted
        case .failure(let failure):
            return .err(
                code: "unavailable",
                message: "next-transport ticket unavailable: \(failure)",
                data: nil)
        }
        let grant: String
        switch runtime.mintGrant(
            deviceID: deviceID, devicePublicKey: key, appIdentity: appIdentity)
        {
        case .success(let minted):
            grant = minted
        case .failure(let failure):
            return .err(
                code: "unavailable",
                message: "next-transport grant unavailable: \(failure)",
                data: nil)
        }
        return .ok([
            "schema_version": 1,
            "ticket": ticket,
            "grant": grant,
        ])
    }

    #if DEBUG
    /// Verifies that a pair request names the already-authenticated caller.
    /// Network sessions must either prove possession of the supplied private
    /// key or match the key/device tuple authenticated by Iroh; the local
    /// control socket remains an explicitly trusted composition-root path.
    nonisolated static func nextTransportPairRequesterIsBound(
        deviceID: String,
        deviceKey: Data,
        appIdentity: String,
        proofBase64: String?,
        authorization: NextTransportPairAuthorization?
    ) -> Bool {
        guard let authorization else { return false }
        let executionContext: MobileHostRPCExecutionContext
        switch authorization {
        case .localControlSocket: return true
        case .mobileRPC(let context): executionContext = context
        }
        // The network bootstrap is exclusively for the signed iOS next-
        // transport client. Other app identities remain available only through
        // the explicitly trusted local control-socket grant command.
        guard appIdentity == "dev.cmux.next.ios" else { return false }
        switch executionContext.authorization {
        case .irohAdmission(let peer):
            guard let endpoint = try? CmxIrohPeerIdentity(
                endpointID: HexEncoding().lowercase(deviceKey)
            ) else { return false }
            return peer.deviceID == deviceID
                && peer.endpointID == endpoint
        case .stackBearer:
            guard let proofBase64,
                let proof = Data(base64Encoded: proofBase64),
                let publicKey = try? Curve25519.Signing.PublicKey(
                    rawRepresentation: deviceKey
                )
            else { return false }
            let transcript = PairingGrant.requestProofTranscript(
                deviceID: deviceID,
                devicePublicKey: deviceKey,
                appIdentity: appIdentity
            )
            return publicKey.isValidSignature(proof, for: transcript)
        }
    }

    #endif
    #endif

}
