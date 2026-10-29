import CmuxMobileAgentChat
import CmuxMobileNotifications
import CmuxMobileTransport
import CryptoKit
import Foundation

/// The first channel of every link (cmux-mobile-host `pairing.rs`, verify/phone-approvals.md):
/// the phone proves its identity key; the Mac serves the link only when the
/// user allowed this phone there, and asks them the first time.
public struct LinkPairing: Sendable {
    public let keys: PhoneKeys
    /// The phone's link device id (the backend stamps it on every signal).
    public let phoneID: String
    /// What the Mac's prompt calls this phone.
    public let name: String

    /// The Macs this phone pinned (first pairing); a Mac that cannot prove its
    /// pinned key is refused `mac_identity_changed`.
    public let pins: MacPins

    /// The push key and the Macs' trust record, shared with the notification
    /// service extension (PROTOCOL.md "Keys at pairing"); nil when the build
    /// has no shared keychain group (or in tests): pushes stay unsealed.
    public let push: PushKeys?

    /// A scanned pairing code waiting for its Mac's challenge (``PairInvite``).
    public let invites: PairInvites

    public init(keys: PhoneKeys, phoneID: String, name: String, pins: MacPins = .standard, push: PushKeys? = nil,
                invites: PairInvites = PairInvites()) {
        self.keys = keys
        self.phoneID = phoneID
        self.name = name
        self.pins = pins
        self.push = push
        self.invites = invites
    }

    /// What the phone says when a paired Mac's identity changed.
    public static let identityChanged = String(localized: """
        This Mac's identity changed, so this iPhone won't connect: it may not be your Mac. \
        If you reinstalled cmux or replaced the Mac, remove it in Settings → Devices, then let it add itself again.
        """)

    /// Where pairing with the linked Mac stands.
    public enum State: Equatable, Sendable {
        case idle
        /// The Mac shows "Allow … to connect?"; the link waits for the answer.
        case waiting(mac: String)
        /// The same, after this phone replaced an unreadable stored key (the
        /// Mac asks again because the key is new).
        case waitingAfterNewKeys(mac: String)
        case paired
        /// The user refused this phone on the Mac.
        case denied(mac: String)
        case failed(String)

        /// The Mac is asking its person about this phone.
        public var isWaiting: Bool {
            switch self {
            case .waiting, .waitingAfterNewKeys: true
            default: false
            }
        }
    }

    /// What the phone says for a refusal `code` from the Mac's `auth`.
    public static func refusalText(_ error: LinkError) -> String {
        switch error.code {
        case "timeout": "nobody answered the Mac's prompt. Retry, then allow this iPhone on the Mac"
        case "rate_limited": "the Mac asked about this iPhone recently: \(error.message)"
        case "busy": "the Mac is already pairing this iPhone"
        case "mac_identity_changed": identityChanged
        case "unavailable": "the Mac isn't ready to pair yet. Retry in a moment"
        default: error.message
        }
    }

    /// What pairing found.
    public enum Outcome: Equatable, Sendable {
        /// Paired: this Mac's device id, for approvals.
        case paired(macDevice: String)
        /// An older Mac without pairing: links work as before, Allow stays on the Mac.
        case legacy
        case refused(LinkError)
    }

    /// An `auth` channel this phone opened, before its challenge is answered.
    public struct Opened: Sendable {
        let channel: any LinkChannel
        let identity: String
        let approval: String
        /// This phone's nonce for the Mac's identity proof.
        let macNonce: String
        /// Whether this `auth` sent the push key (the Mac then proves its box key).
        var sentPushKey = false

        /// Abandons it (the link moved on before the challenge was answered).
        public func close() async { await channel.close(code: "eof", reason: "") }
    }

    /// Opens `auth` on `link`. It costs no round trip, and the Mac holds the
    /// channels the phone opens after it until it passes, so the rest of the
    /// link opens right behind it.
    public func open(link: any MacLink, macID: String? = nil) async -> Result<Opened, LinkError> {
        do {
            let (identity, approval) = try keys.publicKeys()
            let macNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            var args = [
                "identityKey": identity, "approvalKey": approval, "name": String(name.prefix(64)), "action": "pair",
                "macNonce": macNonce,
            ]
            let pushArgs = macID.flatMap { pushKeyArgs(mac: $0) }
            if let pushArgs { args.merge(pushArgs) { a, _ in a } }
            let channel = try await link.openChannel(service: "auth", args: args)
            var opened = Opened(channel: channel, identity: identity, approval: approval, macNonce: macNonce)
            opened.sentPushKey = pushArgs != nil
            return .success(opened)
        } catch let error as LinkError {
            return .failure(error)
        } catch {
            return .failure(LinkError(code: "pairing", message: String(describing: error)))
        }
    }

    /// Runs `auth` on `link`. `onWaiting` fires once if the Mac has to ask the user.
    public func run(link: any MacLink, macID: String, onWaiting: @MainActor @Sendable () -> Void) async -> Outcome {
        await finish(await open(link: link, macID: macID), macID: macID, onWaiting: onWaiting)
    }

    /// The bytes the identity key signs to vouch for the push key.
    public static func pushKeyMessage(mac: String, phone: String, pushKey: String) -> Data {
        PushSeal.joined("cmux-mobile-push-key-v1", [mac, phone, pushKey])
    }

    /// `pushKey` and `pushKeySignature` for `auth` to `mac`; nil without a push key.
    func pushKeyArgs(mac: String) -> [String: String]? {
        guard let push, let user = keys.userID, let key = try? push.publicKey(user: user) else { return nil }
        let hex = PushSignature.hex(key)
        guard let signature = try? keys.signIdentity(Self.pushKeyMessage(mac: mac, phone: phoneID, pushKey: hex)) else { return nil }
        return ["pushKey": hex, "pushKeySignature": PushSignature.hex(signature)]
    }

    /// The bytes the Mac's identity key signs to vouch for its box key.
    public static func boxKeyMessage(mac: String, boxKey: String) -> Data {
        PushSeal.joined("cmux-mobile-mac-box-v1", [mac, boxKey])
    }

    /// The Mac's box key from a challenge, when `identityKey` (proven in this
    /// `auth`, or pinned) signed it and it is a P-256 point; nil otherwise.
    static func boxKey(_ value: JSONValue, mac: String, identityKey: String?) -> String? {
        guard let identityKey, let box = value["macBoxKey"]?.stringValue?.lowercased(), let signature = value["macBoxSignature"]?.stringValue,
              let bytes = PushSignature.hexData(box), (try? P256.KeyAgreement.PublicKey(x963Representation: bytes)) != nil,
              PushSignature.verify(key: identityKey, signature: signature, message: boxKeyMessage(mac: mac, boxKey: box)) else { return nil }
        return box
    }

    /// Answers the challenge on an `auth` channel from ``open(link:)``.
    public func finish(_ auth: Result<Opened, LinkError>, macID: String,
                       onWaiting: @MainActor @Sendable () -> Void) async -> Outcome {
        let opened: Opened
        switch auth {
        case .success(let value): opened = value
        case .failure(let error): return .refused(error)
        }
        let (channel, identity, approval) = (opened.channel, opened.identity, opened.approval)
        defer { Task { await channel.close(code: "eof", reason: "") } }
        let pinned = pins.key(for: macID)
        /// The key this Mac proved in this `auth`, pinned once the Mac lets this phone in.
        var proven: String?
        /// The box key that key vouched for (sealed replies go to it), and its signature.
        var boxKey: String?
        var boxSignature: String?
        do {
            while true {
                guard let frame = try await channel.receive() else {
                    let closed = channel.closedBy ?? LinkError(code: "closed", message: "The Mac closed pairing")
                    // A Mac with no `auth` cannot prove a pinned key either.
                    if closed.code == "unknown_service", pinned != nil { return .refused(Self.changed) }
                    return closed.code == "unknown_service" ? .legacy : .refused(closed)
                }
                let value = try JSONDecoder().decode(JSONValue.self, from: frame)
                if value["ok"] == .bool(true) {
                    if pinned != nil, proven == nil { return .refused(Self.changed) }
                    if pinned == nil, let proven { pins.pin(proven, for: macID) }
                    // The service extension opens this Mac's sealed pushes with the push key
                    // this `auth` sent, checked against the pinned identity key.
                    if let push, let user = keys.userID, let identity = proven ?? pinned {
                        push.trust(mac: macID, identityKey: identity, boxKey: opened.sentPushKey ? boxKey : nil,
                                   boxSignature: boxSignature, user: user, phone: phoneID)
                    }
                    return .paired(macDevice: macID)
                }
                if value["pending"] == .bool(true) {
                    await onWaiting()
                    continue
                }
                guard let nonce = value["challenge"]?.stringValue, let mac = value["mac"]?.stringValue else {
                    return .refused(LinkError(code: "bad_request", message: "The Mac sent an unknown pairing step"))
                }
                // The challenge names the Mac this phone dialed, or it signs nothing.
                guard mac == macID else {
                    return .refused(LinkError(code: "wrong_mac", message: "The Mac answered with another device id"))
                }
                // The Mac's identity key: its proof must hold, and match the pin.
                var provenNow: String?
                switch Self.check(value, mac: mac, phone: phoneID, macNonce: opened.macNonce, challenge: nonce, pinned: pinned) {
                case .proven(let key):
                    proven = key
                    provenNow = key
                case .unproven: break
                case .refused(let error): return .refused(error)
                }
                boxKey = Self.boxKey(value, mac: mac, identityKey: proven)
                boxSignature = boxKey == nil ? nil : value["macBoxSignature"]?.stringValue?.lowercased()
                let payload = LinkAuthPayload(mac: mac, phone: phoneID, nonce: nonce, identityKey: identity,
                                              approvalKey: approval, action: "pair")
                let signature = try keys.signIdentity(payload.message)
                var reply: [String: JSONValue] = ["signature": .string(ApprovalPayload.hex(signature))]
                // A scanned code stands in for the Mac's Allow prompt, only on the Mac that just
                // proved the key the code names (never in `open`'s args, sent before any proof).
                if let token = invites.token(mac: mac, provenKey: provenNow) { reply["pairToken"] = .string(token) }
                try await channel.send(try JSONEncoder().encode(JSONValue.object(reply)))
            }
        } catch let error as LinkError {
            return .refused(error)
        } catch {
            return .refused(LinkError(code: "pairing", message: String(describing: error)))
        }
    }

    static let changed = LinkError(code: "mac_identity_changed", message: identityChanged)

    /// What a challenge says about the Mac's identity.
    enum MacProof: Equatable {
        /// It proved this key.
        case proven(String)
        /// An older Mac that sends no key, and none is pinned.
        case unproven
        case refused(LinkError)
    }

    /// Checks the challenge's `macKey` / `macSignature` against this phone's nonce and the pin.
    static func check(_ value: JSONValue, mac: String, phone: String, macNonce: String, challenge: String,
                      pinned: String?) -> MacProof {
        guard let key = value["macKey"]?.stringValue, let signature = value["macSignature"]?.stringValue else {
            return pinned == nil ? .unproven : .refused(changed)
        }
        let message = MacPins.proofMessage(mac: mac, phone: phone, phoneNonce: macNonce, challenge: challenge)
        guard MacPins.verify(key: key, signature: signature, message: message) else {
            return .refused(pinned == nil ? LinkError(code: "bad_mac_proof", message: "The Mac's identity proof is invalid") : changed)
        }
        if let pinned, pinned != key.lowercased() { return .refused(changed) }
        return .proven(key.lowercased())
    }

    /// "Remove This iPhone from My Macs": asks the Mac to forget this phone (best effort, over a live link).
    public func unpair(link: any MacLink, macID: String) async {
        guard let (identity, approval) = try? keys.publicKeys(),
              let channel = try? await link.openChannel(service: "auth", args: [
                  "identityKey": identity, "approvalKey": approval, "name": "", "action": "unpair",
              ]) else { return }
        defer { Task { await channel.close(code: "eof", reason: "") } }
        guard let frame = try? await channel.receive(), let value = try? JSONDecoder().decode(JSONValue.self, from: frame),
              let nonce = value["challenge"]?.stringValue, value["mac"]?.stringValue == macID else { return }
        let payload = LinkAuthPayload(mac: macID, phone: phoneID, nonce: nonce, identityKey: identity,
                                      approvalKey: approval, action: "unpair")
        guard let signature = try? keys.signIdentity(payload.message),
              let reply = try? JSONEncoder().encode(JSONValue.object(["signature": .string(ApprovalPayload.hex(signature))]))
        else { return }
        try? await channel.send(reply)
        _ = try? await channel.receive()
    }
}
