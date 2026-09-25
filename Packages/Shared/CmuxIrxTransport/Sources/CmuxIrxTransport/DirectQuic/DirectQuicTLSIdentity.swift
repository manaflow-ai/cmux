import Foundation
import Network
import Security

/// The Mac's TLS server identity for Direct QUIC.
///
/// QUIC always runs TLS 1.3, and Network.framework requires the listener to
/// present a certificate. That certificate is deliberately NOT a trust anchor:
/// peers authenticate each other afterwards by signing this connection's TLS
/// exporter with their Ed25519 device keys (`DirectQuicHandshake`). A relay
/// that terminates TLS holds two sessions with two different exporters and
/// cannot produce either device's signature over the other session, so a
/// shared, public certificate key costs nothing. TLS 1.3 key agreement stays
/// ephemeral, so the certificate key cannot decrypt recorded traffic.
enum DirectQuicTLSIdentity {
    static let passphrase = "cmux-direct-quic"

    /// Self-signed P-256 certificate, CN=cmux-direct-quic, valid until 2126.
    static let pkcs12Base64 = """
MIIELAIBAzCCA+IGCSqGSIb3DQEHAaCCA9MEggPPMIIDyzCCAnoGCSqGSIb3DQEHBqCCAmswggJn
AgEAMIICYAYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBDdCwjnu1D1
ZQmgGBaSYafKAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQSby00Z+3LYjvfPnPmoZn
x4CCAfDPG4JzuyaTKBadifiZGDs8wwqAUweEI6hTPJaIHkqhEKRF4uaduZ4QJg8AGWz1HEMdUGnr
zIzX/ER53SQuOpT64Vrd9tzvxkODoxJbIWWj0rWkvAvAdkBYyciih16g+3gZC5b1OPX2gafr/zpo
06cyzbWGg7R8GW0inpZdSVFeV87pXUHeaTzaGyRxsY4lcELG62amdLdmP08XJ6FauNGuuP583GAg
lLKfRr8VebimAfL7ALxXaCWp/hkFPn9DLwWWgtCfFM5+bzU6uefERINu+XMkiBmAtkHpLXu7+hYi
EOccD8BUqyELwpx8oEB2/9ZARAVtx2ZrvLtvFN2liZUFhlIpM2XFniHlmIgJzRZmXpHn8ab2VQWv
lEkuhQI0beZpNg2EOmFqzvUHJrIgt+yEFaDQtjt95riZAIUpex2iSez8bpstnRYNXvb6mwQrJTBA
ZETCWAkFTrkMdB53IHoGDIE+7aeuVo8feMPEjg1wcKAJO8AMh9sBxmmJzPwx8NIgVlP7sE8Kf2ih
2ygZSOUNTYYasmf3KWuZfvksH0uaM7YpxXQx8AjzOBSofwuAaUvCC7lXRHfUpqdO9XCDspGX4ld9
j0p1b8mfsmhJ66fSAJ5o85huN9VjJssPthKQ01HcCSQytlAu25ZONZuzl8YoMIIBSQYJKoZIhvcN
AQcBoIIBOgSCATYwggEyMIIBLgYLKoZIhvcNAQwKAQKggfcwgfQwXwYJKoZIhvcNAQUNMFIwMQYJ
KoZIhvcNAQUMMCQEEK7Nst4CA1NSBgfDVJqzM/ACAggAMAwGCCqGSIb3DQIJBQAwHQYJYIZIAWUD
BAEqBBA6X8x02VXO/Dr6v6sWm5RuBIGQabDgqMuZKzl3d1mrEHq91piB/MZGcH8/M4BgrRQp0QtB
gsWOUTTc3utUlUDUWlFnHzJS7jK0a+hWs+Q1RsUr+IUtLwOTXuAYb0vi8vfVi3NWHunEXSdv1omS
14QSHG1E/P7tlWpveloCikA72wsKjRexMV9sgMspJk35bNPR5XHAvS3vLfGXjdSNIhaf1CSsMSUw
IwYJKoZIhvcNAQkVMRYEFM/1wrX80DNk6FKz9Tt59LTtIqE3MEEwMTANBglghkgBZQMEAgEFAAQg
vAfNkYbr+46FJXF5FyNCVVtth3LvefO6QfLf/WfnIbsECDvvGihiV7xGAgIIAA==
"""

    /// Imports the identity without touching the keychain. In-memory import
    /// needs macOS 15; iOS never serves Direct QUIC.
    static func load() -> sec_identity_t? {
        guard #available(macOS 15.0, iOS 17.0, *),
              let data = Data(base64Encoded: pkcs12Base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        #if os(macOS)
        options[kSecImportToMemoryOnly as String] = true
        #endif
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]],
              let identity = entries.first?[kSecImportItemIdentity as String] else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return sec_identity_create(identity as! SecIdentity)
    }
}
