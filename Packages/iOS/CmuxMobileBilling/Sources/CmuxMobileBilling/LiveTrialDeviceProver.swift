#if canImport(DeviceCheck) && canImport(CryptoKit)
import CryptoKit
import DeviceCheck
import Foundation

/// ``BillingTrialDeviceProving`` over App Attest (`DCAppAttestService`) and
/// DeviceCheck (`DCDevice`).
///
/// The first proof generates and attests a Secure Enclave key; later proofs
/// sign assertions with it. The key id is kept in `UserDefaults`: it is an
/// identifier, not a secret, and the private key never leaves the Secure
/// Enclave. The Simulator supports neither service, so it gets no trial.
public actor LiveTrialDeviceProver: BillingTrialDeviceProving {
    private let defaults: UserDefaults
    private let keyIDDefaultsKey: String

    /// Creates the prover.
    /// - Parameters:
    ///   - defaults: Where the App Attest key id is kept.
    ///   - keyIDDefaultsKey: The defaults key for it.
    public init(defaults: UserDefaults = .standard, keyIDDefaultsKey: String = "cmux.billing.appAttestKeyID") {
        self.defaults = defaults
        self.keyIDDefaultsKey = keyIDDefaultsKey
    }

    public var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        DCAppAttestService.shared.isSupported && DCDevice.current.isSupported
        #endif
    }

    public func proof(clientData: Data) async throws -> BillingTrialDeviceProof {
        guard isSupported else { throw BillingTrialProofError.unsupported }
        let hash = Data(SHA256.hash(data: clientData))
        let service = DCAppAttestService.shared
        let token: Data
        do {
            token = try await DCDevice.current.generateToken()
        } catch {
            throw BillingTrialProofError.deviceCheck
        }
        if let keyID = defaults.string(forKey: keyIDDefaultsKey) {
            do {
                let assertion = try await service.generateAssertion(keyID, clientDataHash: hash)
                return BillingTrialDeviceProof(
                    keyID: keyID,
                    attestation: nil,
                    assertion: assertion.base64EncodedString(),
                    deviceCheckToken: token.base64EncodedString()
                )
            } catch {
                // The key is gone (app reinstall restores defaults from a
                // backup, or the key was invalidated): attest a new one.
                defaults.removeObject(forKey: keyIDDefaultsKey)
            }
        }
        do {
            let keyID = try await service.generateKey()
            let attestation = try await service.attestKey(keyID, clientDataHash: hash)
            defaults.set(keyID, forKey: keyIDDefaultsKey)
            return BillingTrialDeviceProof(
                keyID: keyID,
                attestation: attestation.base64EncodedString(),
                assertion: nil,
                deviceCheckToken: token.base64EncodedString()
            )
        } catch {
            throw BillingTrialProofError.attest
        }
    }

    public func resetKey() {
        defaults.removeObject(forKey: keyIDDefaultsKey)
    }
}
#endif
