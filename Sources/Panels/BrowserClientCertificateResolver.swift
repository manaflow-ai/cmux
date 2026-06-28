import Foundation
import Security

/// Resolves and presents a TLS client-certificate identity for a mutual-TLS
/// (mTLS) challenge so the embedded browser can reach client-cert-gated origins
/// (corporate zero-trust / device-attestation endpoints, MDM-enrolled client
/// certs, Entra Conditional Access) the same way a system browser does, instead
/// of failing the handshake.
///
/// `.performDefaultHandling` is not sufficient for a client-certificate
/// challenge: the system presents no certificate, so a mutual-TLS endpoint
/// rejects the connection. This resolver finds a matching identity in the
/// system keychain and the caller presents it with `.useCredential`.
///
/// Note: a hardware-backed (Secure Enclave) identity is usable only by an
/// application entitled to its keychain access group, so it can only be presented
/// by a suitably code-signed build. An extractable identity in the system
/// keychain works without that entitlement.
enum BrowserClientCertificateResolver {
    /// Answer a client-certificate (mutual-TLS) challenge by presenting a matching
    /// system-keychain identity, or deferring to the system when none matches.
    ///
    /// Returns true when `challenge` was a client-certificate challenge (and the
    /// completion handler has been invoked); returns false for every other
    /// challenge kind so the caller applies its own default handling. Sharing this
    /// across every browser navigation delegate keeps mTLS behavior identical for
    /// the main browser and for popup/auth windows.
    @discardableResult
    static func handleIfClientCertificate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
        else { return false }

        if let credential = credential(for: challenge.protectionSpace) {
            completionHandler(.useCredential, credential)
        } else {
            // No confident keychain match: defer to the system (it may present a
            // picker or proceed without a certificate), preserving prior behavior.
            completionHandler(.performDefaultHandling, nil)
        }
        return true
    }

    static func credential(for protectionSpace: URLProtectionSpace) -> URLCredential? {
        guard let identity = identity(for: protectionSpace) else { return nil }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    static func identity(for protectionSpace: URLProtectionSpace) -> SecIdentity? {
        // The CAs the server advertised as acceptable in its TLS CertificateRequest
        // (DER-encoded X.500 names). Used both to constrain a host preference and to
        // match by issuer; may be empty if the server did not advertise a list.
        let acceptableIssuers = protectionSpace.distinguishedNames ?? []
        let issuerFilter = acceptableIssuers.isEmpty ? nil : acceptableIssuers as CFArray

        // 1. A host-specific keychain identity preference (the user's explicit
        //    choice for this host, what a system browser records on first use),
        //    constrained to the server's acceptable issuers so a stale preference
        //    can't present a certificate the server never asked for. Try the bare
        //    host and the URL forms a browser typically records.
        let host = protectionSpace.host
        let candidates = [host, "https://\(host)", "https://\(host):\(protectionSpace.port)"]
        for name in candidates {
            if let preferred = SecIdentityCopyPreferred(name as CFString, nil, issuerFilter) {
                return preferred
            }
        }

        // 2. Otherwise, ask the keychain for any identity whose certificate was
        //    issued by one of the acceptable CAs. Letting the keychain do the match
        //    avoids issuer-DN normalization pitfalls.
        guard !acceptableIssuers.isEmpty else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchIssuers: acceptableIssuers,
            kSecReturnRef: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let item, CFGetTypeID(item) == SecIdentityGetTypeID() {
            return (item as! SecIdentity)
        }
        return nil
    }
}
