import Foundation
import Security

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
#if DEBUG
            if status != errSecItemNotFound {
                cmuxDebugLog("browser.clientCertificate.identityLookup status=\(status)")
            }
#endif
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
#if DEBUG
            cmuxDebugLog("browser.clientCertificate.copyCertificate status=\(status)")
#endif
            return nil
        }

        let credential = URLCredential(
            identity: identity,
            certificates: [certificate],
            persistence: .forSession
        )
        return BrowserClientCertificateCredentialCandidate(
            title: SecCertificateCopySubjectSummary(certificate) as String?,
            subtitle: nil,
            credential: credential
        )
    }
}
