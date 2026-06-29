import Foundation
import LocalAuthentication
import OSLog
import Security

nonisolated private let browserClientCertificateLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "BrowserClientCertificate"
)

private let browserClientCertificateTLSClientAuthenticationEKU = Data([
    0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02,
])

private let browserClientCertificateAnyExtendedKeyUsageEKU = Data([
    0x55, 0x1D, 0x25, 0x00,
])

func browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication(_ value: Any?) -> Bool {
    guard let value else {
        return true
    }

    var foundExtendedKeyUsage = false
    var allowsTLSClientAuthentication = false

    func collectOIDValues(from value: Any) {
        if let data = value as? Data {
            foundExtendedKeyUsage = true
            if data == browserClientCertificateTLSClientAuthenticationEKU
                || data == browserClientCertificateAnyExtendedKeyUsageEKU {
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

struct BrowserClientCertificateCredentialStore {
    func candidates(for protectionSpace: URLProtectionSpace) -> [BrowserClientCertificateCredentialCandidate] {
        guard let query = identityLookupQuery(for: protectionSpace) else {
            browserClientCertificateLogger.info(
                "browser.clientCertificate.identityLookupSkipped reason=missingAcceptedIssuers"
            )
            return []
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            if status == errSecInteractionNotAllowed {
                browserClientCertificateLogger.info(
                    "browser.clientCertificate.identityLookupSkipped reason=interactionNotAllowed"
                )
            } else if status != errSecItemNotFound {
                browserClientCertificateLogger.error(
                    "browser.clientCertificate.identityLookup status=\(status, privacy: .public)"
                )
            }
            return []
        }

        return identities(from: result).compactMap(candidate(for:))
    }

    func identityLookupQuery(for protectionSpace: URLProtectionSpace) -> [String: Any]? {
        identityLookupQuery(acceptedIssuers: protectionSpace.distinguishedNames)
    }

    func identityLookupQuery(acceptedIssuers: [Data]?) -> [String: Any]? {
        guard let acceptedIssuers, !acceptedIssuers.isEmpty else {
            return nil
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: noninteractiveAuthenticationContext(),
        ]
        query[kSecMatchIssuers as String] = acceptedIssuers as CFArray

        return query
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
            browserClientCertificateLogger.error(
                "browser.clientCertificate.copyCertificate status=\(status, privacy: .public)"
            )
            return nil
        }

        guard certificateAllowsTLSClientAuthentication(certificate) else {
            browserClientCertificateLogger.info(
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
            subtitle: certificateSerialNumberSubtitle(for: certificate),
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
                browserClientCertificateLogger.error(
                    "browser.clientCertificate.copyExtendedKeyUsage error=\((error.takeRetainedValue() as Error).localizedDescription, privacy: .public)"
                )
            }
            return false
        }

        guard let extendedKeyUsage = values[kSecOIDExtendedKeyUsage as String] else {
            return true
        }

        if let dictionary = extendedKeyUsage as? [String: Any],
           let value = dictionary[kSecPropertyKeyValue as String] {
            return browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication(value)
        }

        return browserClientCertificateExtendedKeyUsageAllowsTLSClientAuthentication(extendedKeyUsage)
    }

    private func certificateSerialNumberSubtitle(for certificate: SecCertificate) -> String? {
        var error: Unmanaged<CFError>?
        guard let serialNumberData = SecCertificateCopySerialNumberData(certificate, &error) as Data? else {
            return nil
        }

        let serialNumber = hexString(for: serialNumberData)
        guard !serialNumber.isEmpty else { return nil }

        let format = String(
            localized: "browser.dialog.clientCertificate.serialNumber",
            defaultValue: "Serial %@"
        )
        return String(format: format, locale: Locale.current, serialNumber)
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
