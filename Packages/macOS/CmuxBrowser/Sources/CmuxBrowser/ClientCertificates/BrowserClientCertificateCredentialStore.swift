public import Foundation

import LocalAuthentication
import OSLog
import Security

/// Looks up macOS Keychain identities that can answer browser client-certificate challenges.
public struct BrowserClientCertificateCredentialStore {
    private static let tlsClientAuthenticationEKU = Data([
        0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02,
    ])

    private static let anyExtendedKeyUsageEKU = Data([
        0x55, 0x1D, 0x25, 0x00,
    ])

    private let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "BrowserClientCertificate"
    )

    /// Creates a Keychain-backed credential store.
    public init() {}

    /// Looks up candidates from the macOS Keychain without blocking the main actor.
    /// - Parameters:
    ///   - protectionSpace: The WebKit protection space from the client-certificate challenge.
    ///   - completion: Main-actor callback receiving matching candidates.
    /// - Returns: A cancellation callback for the in-flight lookup task.
    public func lookupCandidates(
        protectionSpace: URLProtectionSpace,
        completion: @escaping @MainActor @Sendable ([BrowserClientCertificateCredentialCandidate]) -> Void
    ) -> BrowserClientCertificateAuthenticationHandler.CandidateLookupCancellation {
        let acceptedIssuers = protectionSpace.distinguishedNames
        let lookupTask = Task.detached(priority: .userInitiated) {
            let candidates = BrowserClientCertificateCredentialStore().candidates(acceptedIssuers: acceptedIssuers)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                completion(candidates)
            }
        }
        return {
            lookupTask.cancel()
        }
    }

    /// Returns credential candidates matching the server's accepted issuers.
    /// - Parameter protectionSpace: The WebKit protection space from the client-certificate challenge.
    /// - Returns: Client-certificate candidates, or an empty array when none can be used.
    public func candidates(for protectionSpace: URLProtectionSpace) -> [BrowserClientCertificateCredentialCandidate] {
        candidates(acceptedIssuers: protectionSpace.distinguishedNames)
    }

    /// Returns credential candidates for the accepted issuer distinguished names.
    /// - Parameter acceptedIssuers: DER-encoded issuer names advertised by the server, or `nil`/empty when omitted.
    /// - Returns: Client-certificate candidates, or an empty array when none can be used.
    public func candidates(acceptedIssuers: [Data]?) -> [BrowserClientCertificateCredentialCandidate] {
        let query = identityLookupQuery(acceptedIssuers: acceptedIssuers)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            if status == errSecInteractionNotAllowed {
                logger.info(
                    "browser.clientCertificate.identityLookupSkipped reason=interactionNotAllowed"
                )
            } else if status != errSecItemNotFound {
                logger.error(
                    "browser.clientCertificate.identityLookup status=\(status, privacy: .public)"
                )
            }
            return []
        }

        return identities(from: result).compactMap(candidate(for:))
    }

    func identityLookupQuery(for protectionSpace: URLProtectionSpace) -> [String: Any] {
        identityLookupQuery(acceptedIssuers: protectionSpace.distinguishedNames)
    }

    func identityLookupQuery(acceptedIssuers: [Data]?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: noninteractiveAuthenticationContext(),
        ]

        if let acceptedIssuers, !acceptedIssuers.isEmpty {
            query[kSecMatchIssuers as String] = acceptedIssuers as CFArray
        }

        return query
    }

    func extendedKeyUsageAllowsTLSClientAuthentication(_ value: Any?) -> Bool {
        guard let value else {
            return true
        }

        var foundExtendedKeyUsage = false
        var allowsTLSClientAuthentication = false

        func collectOIDValues(from value: Any) {
            if let data = value as? Data {
                foundExtendedKeyUsage = true
                if data == Self.tlsClientAuthenticationEKU
                    || data == Self.anyExtendedKeyUsageEKU {
                    allowsTLSClientAuthentication = true
                }
                return
            }

            if let string = value as? String {
                foundExtendedKeyUsage = true
                switch string {
                case "1.3.6.1.5.5.7.3.2", "2.5.29.37.0":
                    allowsTLSClientAuthentication = true
                default:
                    break
                }
                return
            }

            if let dictionary = value as? [String: Any] {
                if let nestedValue = dictionary[kSecPropertyKeyValue as String] {
                    collectOIDValues(from: nestedValue)
                }
                return
            }

            if let array = value as? [Any] {
                for nestedValue in array {
                    collectOIDValues(from: nestedValue)
                }
            }
        }

        collectOIDValues(from: value)
        return foundExtendedKeyUsage && allowsTLSClientAuthentication
    }

    private func noninteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private func identities(from result: CFTypeRef) -> [SecIdentity] {
        if CFGetTypeID(result) == SecIdentityGetTypeID() {
            return [result as! SecIdentity]
        }
        guard CFGetTypeID(result) == CFArrayGetTypeID(),
              let values = result as? [Any] else {
            return []
        }
        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == SecIdentityGetTypeID() else { return nil }
            return (cfValue as! SecIdentity)
        }
    }

    private func candidate(for identity: SecIdentity) -> BrowserClientCertificateCredentialCandidate? {
        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)
        guard status == errSecSuccess, let certificate else {
            logger.error(
                "browser.clientCertificate.copyCertificate status=\(status, privacy: .public)"
            )
            return nil
        }

        guard certificateAllowsTLSClientAuthentication(certificate) else {
            logger.info(
                "browser.clientCertificate.identityFiltered reason=extendedKeyUsage"
            )
            return nil
        }

        let credential = URLCredential(
            identity: identity,
            certificates: [certificate],
            persistence: .forSession
        )
        return BrowserClientCertificateCredentialCandidate(
            title: SecCertificateCopySubjectSummary(certificate) as String?,
            serialNumber: certificateSerialNumber(for: certificate),
            credential: credential
        )
    }

    private func certificateAllowsTLSClientAuthentication(_ certificate: SecCertificate) -> Bool {
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDExtendedKeyUsage] as CFArray,
            &error
        ) as? [String: Any] else {
            if let error {
                logger.error(
                    "browser.clientCertificate.copyExtendedKeyUsage error=\((error.takeRetainedValue() as any Error).localizedDescription, privacy: .public)"
                )
            }
            return false
        }

        guard let extendedKeyUsage = values[kSecOIDExtendedKeyUsage as String] else {
            return true
        }

        if let dictionary = extendedKeyUsage as? [String: Any],
           let value = dictionary[kSecPropertyKeyValue as String] {
            return extendedKeyUsageAllowsTLSClientAuthentication(value)
        }

        return extendedKeyUsageAllowsTLSClientAuthentication(extendedKeyUsage)
    }

    private func certificateSerialNumber(for certificate: SecCertificate) -> String? {
        var error: Unmanaged<CFError>?
        guard let serialNumberData = SecCertificateCopySerialNumberData(certificate, &error) as Data? else {
            return nil
        }

        let serialNumber = hexString(for: serialNumberData)
        return serialNumber.isEmpty ? nil : serialNumber
    }

    private func hexString(for data: Data) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
