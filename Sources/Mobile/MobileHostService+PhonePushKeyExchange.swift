import CMUXMobileCore
import CmuxPhonePush
import Foundation

extension MobileHostService {
    func handlePhonePushKeyExchange(
        _ request: MobileHostRPCRequest
    ) async -> MobileHostRPCResult {
        do {
            let data = try JSONSerialization.data(withJSONObject: request.params)
            let exchange = try JSONDecoder().decode(
                MobilePhonePushKeyExchangeRequest.self,
                from: data
            )
            try exchange.validate()
            guard let accountID = await currentAuthenticatedLocalUserID(), !accountID.isEmpty else {
                return .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Mobile push key exchange requires a signed-in Mac."
                ))
            }

            let macDeviceID = MobileHostIdentity.deviceID()
            let macInstanceTag = MobileHostIdentity.instanceTag()
            let macBuildID = Bundle.main.bundleIdentifier ?? "cmux"
            let macKey = try PhonePushKeyMaterial.current(bundleID: macBuildID)

            // The account and Mac identity are all derived locally. The phone
            // supplies only its key descriptor, build label, and independent
            // RPC installation client ID; descriptor.installationID is never
            // assumed to equal client_id.
            let tuple = PhonePushDeviceTuple(
                accountID: accountID,
                teamID: nil,
                iosBuildID: exchange.iosBuildID,
                iosInstallationID: exchange.descriptor.installationID,
                macDeviceID: macDeviceID,
                macInstanceTag: macInstanceTag,
                macBuildID: macBuildID
            )
            PhonePushPeerKeyStore().pin(
                exchange.descriptor.publicKey,
                keyID: exchange.descriptor.keyID,
                for: tuple
            )

            let result = MobilePhonePushKeyExchangeResponse(
                descriptor: MobilePhonePushPublicKeyDescriptor(
                    installationID: macKey.installationID,
                    keyID: macKey.keyID,
                    publicKey: macKey.publicKeyData
                ),
                accountID: accountID,
                macDeviceID: macDeviceID,
                macInstanceTag: macInstanceTag,
                macBuildID: macBuildID
            )
            let resultData = try JSONEncoder().encode(result)
            let payload = try JSONSerialization.jsonObject(with: resultData)
            return .ok(payload)
        } catch let error as MobilePhonePushKeyExchangeError {
            return .failure(MobileHostRPCError(
                code: "invalid_request",
                message: String(describing: error)
            ))
        } catch {
            return .failure(MobileHostRPCError(
                code: "invalid_request",
                message: "Invalid mobile push key exchange request."
            ))
        }
    }
}
