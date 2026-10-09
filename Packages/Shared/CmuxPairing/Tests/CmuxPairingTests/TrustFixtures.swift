import CmuxMobileWire
import CmuxPairing
import CryptoKit
import Foundation

/// Accounts, devices and owner frames shaped like the backend's `trust:` stream.
struct TrustFixtures {
    static let env = "test"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let nowMillis: Int64 = 1_800_000_000_000

    let mac = SoftwareSigner()
    let phone = SoftwareSigner()
    let guestPhone = SoftwareSigner()
    let otherMac = SoftwareSigner()
    let macKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let guestKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    let otherMacKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

    func cert(_ signer: SoftwareSigner, user: String, install: String, key: Data, purpose: LinkPurpose = .direct) async throws -> LinkCertificate {
        try await LinkCertificateIssuer(environment: Self.env, user: user, install: install, signer: signer).issue(purpose: purpose, key: key, now: Self.now)
    }

    func keySet(_ signer: SoftwareSigner, install: String, kind: String, name: String, host: String?, cert: LinkCertificate, seq: UInt64) throws -> EventFrame {
        var params: [String: JSONValue] = ["cert": try JSONValue(encoding: cert), "kind": .string(kind), "name": .string(name),
                                           "platform": .string(kind == "mac" ? "macos" : "ios"), "public_jwk": try JSONValue(encoding: signer.publicKey)]
        if let host { params["host"] = .string(host) }
        return event("trust.key.set", .object(params), seq: seq)
    }

    func event(_ op: String, _ params: JSONValue, seq: UInt64) -> EventFrame {
        EventFrame(stream: "trust:user_a1", seq: seq, tx: "tx_\(seq)", op: op, params: params, actor: [:], origin: .script, at: Self.nowMillis + Int64(seq))
    }

    func peer(_ signer: SoftwareSigner, install: String, user: String, cert: LinkCertificate) throws -> [String: JSONValue] {
        ["install": .string(install), "user": .string(user), "user_name": .string("Bea"), "name": .string("iPhone"), "platform": .string("ios"),
         "public_jwk": try JSONValue(encoding: signer.publicKey), "cert": try JSONValue(encoding: cert)]
    }

    /// Own Mac (host_a1) and phone, a guest on the Mac, and another account's host the phone was accepted on.
    func populated() async throws -> TrustStoreState {
        var state = TrustStoreState()
        try state.apply(try keySet(mac, install: "inst_m1", kind: "mac", name: "Studio", host: "host_a1",
                                   cert: try await cert(mac, user: "user_a1", install: "inst_m1", key: macKey), seq: 1))
        try state.apply(try keySet(phone, install: "inst_p1", kind: "ios", name: "iPhone", host: nil,
                                   cert: try await cert(phone, user: "user_a1", install: "inst_p1", key: phoneKey), seq: 2))
        var guest = try peer(guestPhone, install: "inst_g1", user: "user_b1", cert: try await cert(guestPhone, user: "user_b1", install: "inst_g1", key: guestKey))
        guest["offer_id"] = .string(String(repeating: "o", count: 43))
        guest["host"] = .string("host_a1")
        guest["team"] = .string("team_a1")
        try state.apply(event("trust.guest.add", .object(guest), seq: 3))
        let remote: [String: JSONValue] = [
            "host": .string("host_b1"), "team": .string("team_b1"), "owner_user": .string("user_b1"), "name": .string("Bea's Mac"),
            "host_install": .string("inst_bm"), "public_jwk": try JSONValue(encoding: otherMac.publicKey),
            "cert": try JSONValue(encoding: try await cert(otherMac, user: "user_b1", install: "inst_bm", key: otherMacKey)),
            "install": .string("inst_p1"), "offer_id": .string(String(repeating: "r", count: 43)),
        ]
        try state.apply(event("trust.remote.add", .object(remote), seq: 4))
        return state
    }
}
