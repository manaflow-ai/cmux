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
/// Note: this works from an unsigned (ad-hoc) build with no special entitlement.
/// A hardware-backed identity held in a CryptoTokenKit token (e.g. Secure
/// Enclave) is presented through the token, which brokers the signing operation,
/// so the browser does not need the token's keychain access group. An extractable
/// software identity in the system keychain works the same way. (Verified
/// empirically against a real mutual-TLS origin from an ad-hoc-signed build.)
nonisolated struct BrowserClientCertificateResolver: Sendable {
    /// Answer a client-certificate (mutual-TLS) challenge by presenting a matching
    /// system-keychain identity, or deferring to the system when none matches.
    ///
    /// Returns true when `challenge` was a client-certificate challenge (so the
    /// caller must not also answer it — the completion handler is invoked
    /// asynchronously); returns false for every other challenge kind so the
    /// caller applies its own default handling. The cheap synchronous check is
    /// only the authentication method; the keychain lookup itself runs off the
    /// caller's (main) actor because `SecIdentityCopyPreferred` /
    /// `SecItemCopyMatching` are synchronous and can block or trigger an auth
    /// prompt — doing that inline during the handshake would freeze the browser
    /// window. Sharing this across every browser navigation delegate keeps mTLS
    /// behavior identical for the main browser and for popup/auth windows.
    @discardableResult
    func handleIfClientCertificate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate
        else { return false }

        let protectionSpace = challenge.protectionSpace
        DispatchQueue.global(qos: .userInitiated).async {
            if let credential = self.credential(for: protectionSpace) {
                completionHandler(.useCredential, credential)
            } else {
                // No confident keychain match: defer to the system (it may present
                // a picker or proceed without a certificate), preserving prior
                // behavior.
                completionHandler(.performDefaultHandling, nil)
            }
        }
        return true
    }

    private func credential(for protectionSpace: URLProtectionSpace) -> URLCredential? {
        guard let identity = identity(for: protectionSpace) else { return nil }
        return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
    }

    private func identity(for protectionSpace: URLProtectionSpace) -> SecIdentity? {
        // The CAs the server advertised as acceptable in its TLS CertificateRequest
        // (DER-encoded X.500 names). Used both to constrain a host preference and to
        // match by issuer; may be empty if the server did not advertise a list.
        let acceptableIssuers = protectionSpace.distinguishedNames ?? []
        let issuerFilter = acceptableIssuers.isEmpty ? nil : acceptableIssuers as CFArray

        // 1. A host-specific keychain identity preference (the user's explicit
        //    choice for this host, what a system browser records on first use),
        //    constrained to the server's acceptable issuers so a stale preference
        //    can't present a certificate the server never asked for. Only consult
        //    the preference when the server advertised acceptable issuers — with no
        //    issuer constraint a stale preference would be presented unconditionally,
        //    so we fail closed (defer to the system) instead. Try the bare host and
        //    the URL forms a browser typically records.
        if let issuerFilter {
            let host = protectionSpace.host
            let candidates = [host, "https://\(host)", "https://\(host):\(protectionSpace.port)"]
            for name in candidates {
                if let preferred = SecIdentityCopyPreferred(name as CFString, nil, issuerFilter) {
                    return preferred
                }
            }
        }

        // 2. Otherwise, ask the keychain for every identity whose certificate was
        //    issued by one of the acceptable CAs. Letting the keychain do the match
        //    avoids issuer-DN normalization pitfalls.
        guard !acceptableIssuers.isEmpty else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchIssuers: acceptableIssuers,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }
        // Fail closed: only auto-present when exactly one identity is eligible. If
        // several match the server's acceptable issuers and the user expressed no
        // host preference, defer to the system picker rather than silently choosing
        // a certificate on their behalf.
        guard identities.count == 1 else { return nil }
        return identities.first
    }
}
