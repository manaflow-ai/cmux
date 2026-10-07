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
                let wg = device.certs.wg.flatMap { valid($0, key: device.publicKey, user: user, install: device.install, purpose: .wg, at: at) ? $0.keyBytes : nil }
                return TrustedHostKey(host: host, install: device.install, name: device.name, ownerUser: user, directKey: raw,
                                      certificate: cert, isOwnAccount: true, installKey: device.publicKey, wireGuardKey: wg)
            }
        }
        for entry in state.remote.values.sorted(by: { $0.install < $1.install }) where entry.host == host {
            if valid(entry.cert, key: entry.publicKey, user: entry.ownerUser, install: entry.hostInstall, purpose: .direct, at: at),
               let raw = entry.cert.keyBytes {
                return TrustedHostKey(host: host, install: entry.hostInstall, name: entry.name, ownerUser: entry.ownerUser,
                                      directKey: raw, certificate: entry.cert, isOwnAccount: false, installKey: entry.publicKey,
                                      team: entry.team)
            }
        }
        return nil
    }

    public func isTrustedDevice(directKey: Data, onHost host: String?) async -> Bool {
        await trustedInstall(linkKey: directKey, purpose: .direct, onHost: host) != nil
    }

    public func trustedInstall(linkKey: Data, purpose: LinkPurpose, onHost host: String?) async -> String? {
        guard let state = await mirror.state, linkKey.count == 32, purpose != .dtls else { return nil }
        let at = millis()
        let encoded = linkKey.base64URLEncodedString()
        if let device = state.devices.values.sorted(by: { $0.install < $1.install }).first(where: { d in
            d.certs[purpose].map { $0.key == encoded && valid($0, key: d.publicKey, user: user, install: d.install, purpose: purpose, at: at) } ?? false
        }) { return device.install }
        guard let host, purpose == .direct else { return nil }
        return state.guests.values.sorted(by: { $0.device.install < $1.device.install }).first { g in
            g.host == host && g.device.cert.key == encoded
                && valid(g.device.cert, key: g.device.publicKey, user: g.device.user, install: g.device.install, purpose: .direct, at: at)
        }?.device.install
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
