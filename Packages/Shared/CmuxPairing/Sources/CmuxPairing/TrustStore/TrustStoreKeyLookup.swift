public import Foundation

/// `TrustedKeyLookup` over a `TrustStoreMirror`.
public struct TrustStoreKeyLookup: TrustedKeyLookup {
    private let mirror: TrustStoreMirror
    private let environment: String
    private let user: String
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - environment: the API environment the certs were signed for.
    ///   - user: this account's user id (`user_…`).
    public init(mirror: TrustStoreMirror, environment: String, user: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.mirror = mirror
        self.environment = environment
        self.user = user
        self.now = now
    }

    public func hostKey(for host: String) async -> TrustedHostKey? {
        guard let state = await mirror.state else { return nil }
        let at = millis()
        for device in state.devices.values.sorted(by: { $0.install < $1.install }) where device.host == host {
            if let cert = device.certs.direct, valid(cert, key: device.publicKey, user: user, install: device.install, purpose: .direct, at: at),
               let raw = cert.keyBytes {
                return TrustedHostKey(host: host, install: device.install, name: device.name, ownerUser: user, directKey: raw,
                                      certificate: cert, isOwnAccount: true)
            }
        }
        for entry in state.remote.values.sorted(by: { $0.install < $1.install }) where entry.host == host {
            if valid(entry.cert, key: entry.publicKey, user: entry.ownerUser, install: entry.hostInstall, purpose: .direct, at: at),
               let raw = entry.cert.keyBytes {
                return TrustedHostKey(host: host, install: entry.hostInstall, name: entry.name, ownerUser: entry.ownerUser,
                                      directKey: raw, certificate: entry.cert, isOwnAccount: false)
            }
        }
        return nil
    }

    public func isTrustedDevice(directKey: Data, onHost host: String?) async -> Bool {
        guard let state = await mirror.state, directKey.count == 32 else { return false }
        let at = millis()
        let encoded = directKey.base64URLEncodedString()
        if state.devices.values.contains(where: { d in
            d.certs.direct.map { $0.key == encoded && valid($0, key: d.publicKey, user: user, install: d.install, purpose: .direct, at: at) } ?? false
        }) { return true }
        guard let host else { return false }
        return state.guests.values.contains { g in
            g.host == host && g.device.cert.key == encoded
                && valid(g.device.cert, key: g.device.publicKey, user: g.device.user, install: g.device.install, purpose: .direct, at: at)
        }
    }

    public func verifyFingerprint(_ certificate: LinkCertificate, from install: String) async -> Bool {
        guard let state = await mirror.state, certificate.purpose == .dtls else { return false }
        let at = millis()
        if let d = state.devices[install] { return valid(certificate, key: d.publicKey, user: user, install: install, purpose: .dtls, at: at) }
        if let g = state.guests.values.first(where: { $0.device.install == install }) {
            return valid(certificate, key: g.device.publicKey, user: g.device.user, install: install, purpose: .dtls, at: at)
        }
        if let r = state.remote.values.first(where: { $0.hostInstall == install }) {
            return valid(certificate, key: r.publicKey, user: r.ownerUser, install: install, purpose: .dtls, at: at)
        }
        return false
    }

    private func millis() -> Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) }

    private func valid(_ cert: LinkCertificate, key: InstallPublicKey, user: String, install: String, purpose: LinkPurpose, at: Int64) -> Bool {
        guard cert.purpose == purpose, cert.user == user, cert.install == install, let signing = key.signingKey else { return false }
        return (try? cert.verify(installKey: signing, environment: environment, now: at)) != nil
    }
}
