import Foundation
import OSLog
import Security

nonisolated private let browserClientCertificateLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "BrowserClientCertificate"
)

struct BrowserClientCertificateCredentialStore {
    func candidates(for protectionSpace: URLProtectionSpace) -> [BrowserClientCertificateCredentialCandidate] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        if let distinguishedNames = protectionSpace.distinguishedNames,
           !distinguishedNames.isEmpty {
            query[kSecMatchIssuers as String] = distinguishedNames as CFArray
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            if status != errSecItemNotFound {
                browserClientCertificateLogger.error(
                    "browser.clientCertificate.identityLookup status=\(status, privacy: .public)"
                )
            }
            return []
        }

        return identities(from: result).compactMap(candidate(for:))
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
