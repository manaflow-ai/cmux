import Foundation

/// A sealed push (`cmuxMobile.v` 3, PROTOCOL.md "Sealed notify"): the Mac
/// sealed the v2 content to this phone's push key and signed it with its
/// identity key. APNs and the Worker see only the kind, the ids and a generic
/// banner; the notification service extension opens it.
public struct SealedPush: Sendable, Equatable {
    public enum Failure: Error, Equatable, Sendable {
        /// No trust record, or the Mac is not one this phone paired with.
        case unknownMac
        /// The Mac identity signature does not verify.
        case badSignature
        /// The box would not open with this phone's push key.
        case unopened
        /// It opened, but is not a push for this Mac and event.
        case mismatch
    }

    public var mac: String
    public var macName: String?
    public var kind: PushKind
    public var eventId: String
    public var box: String
    public var sig: String
    /// The phone's Show previews (the Worker sets it per phone).
    public var previews: Bool

    public init(mac: String, macName: String? = nil, kind: PushKind, eventId: String, box: String, sig: String, previews: Bool = true) {
        self.mac = mac
        self.macName = macName
        self.kind = kind
        self.eventId = eventId
        self.box = box
        self.sig = sig
        self.previews = previews
    }

    /// Reads `userInfo["cmuxMobile"]` of a v3 push; nil for anything else.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let object = userInfo[PushPayload.userInfoKey] as? [String: Any], (object["v"] as? Int) == 3,
              let mac = object["mac"] as? String, !mac.isEmpty, let kind = (object["kind"] as? String).flatMap(PushKind.init(rawValue:)),
              let eventId = object["eventId"] as? String, !eventId.isEmpty,
              let box = object["box"] as? String, let sig = object["sig"] as? String else { return nil }
        self.init(mac: mac, macName: object["macName"] as? String, kind: kind, eventId: eventId, box: box, sig: sig,
                  previews: object["previews"] as? Bool ?? true)
    }

    /// The bytes the Mac identity key signs.
    public static func signedMessage(mac: String, phone: String, eventId: String, box: String) -> Data {
        PushSeal.joined("cmux-mobile-push-v1", [mac, phone, eventId, box])
    }

    /// Checks the signature against the Mac's pinned key, opens the box with
    /// this phone's push key, and returns the v2 payload it carries.
    public func open(trust: PushTrust?, keys: PushKeys) throws -> PushPayload {
        guard let trust, let pinned = trust.macs[mac.lowercased()] else { throw Failure.unknownMac }
        guard PushSignature.verify(key: pinned.identityKey, signature: sig,
                                   message: Self.signedMessage(mac: mac, phone: trust.phone, eventId: eventId, box: box)) else {
            throw Failure.badSignature
        }
        let plaintext: Data
        do {
            plaintext = try keys.open(box, user: trust.user, context: PushSeal.pushContext(mac: mac, phone: trust.phone, eventId: eventId))
        } catch {
            throw Failure.unopened
        }
        guard var payload = try? JSONDecoder().decode(PushPayload.self, from: plaintext),
              payload.mac?.lowercased() == mac.lowercased(), payload.eventId == eventId, payload.kind == kind else {
            throw Failure.mismatch
        }
        payload.previews = previews
        if payload.macName == nil { payload.macName = macName }
        return payload
    }
}

/// The banner a payload shows: the Worker's text for a v2 push
/// (`backend/src/push.ts` `alert`), written on the phone for a sealed one.
public struct PushBanner: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var body: String

    public init(title: String, subtitle: String? = nil, body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// The generic banner of a sealed push before it opens (and when it can't).
    public static func generic(macName: String?) -> PushBanner {
        PushBanner(title: "cmux", body: String(localized: "New notification from \(macName ?? String(localized: "your Mac"))"))
    }

    static func fixedTitle(_ kind: PushKind, agent: String) -> String {
        switch kind {
        case .question: String(localized: "\(agent) has a question")
        case .permission: String(localized: "\(agent) needs permission")
        case .completed: String(localized: "\(agent) finished")
        case .failed: String(localized: "\(agent) stopped with an error")
        case .chief: String(localized: "Chief replied")
        case .terminal: String(localized: "Terminal")
        }
    }

    public init(payload p: PushPayload) {
        let agent = p.agent ?? String(localized: "Your agent")
        let mac = p.macDisplayName
        let place = p.placeName
        let rich = p.title != nil || p.body != nil || !p.tail.isEmpty || !p.questions.isEmpty
        guard p.previews else {
            self.init(title: Self.fixedTitle(p.kind, agent: agent), body: mac)
            return
        }
        guard rich else {
            self.init(title: Self.fixedTitle(p.kind, agent: agent), body: place.map { "\($0) · \(mac)" } ?? mac)
            return
        }
        let last = p.tail.last.flatMap { $0.isEmpty ? nil : $0 }
        let title: String
        let body: String
        switch p.kind {
        case .question:
            title = String(localized: "\(agent) asks")
            body = p.questions.first.map(\.question).flatMap { $0.isEmpty ? nil : $0 } ?? p.title ?? ""
        case .permission:
            // As the Mac's approval prompt (`ApprovalBanner`): the Mac is in the title, the request below.
            title = ApprovalBanner.title(agent: agent, mac: mac)
            body = ApprovalBanner.detail(p) ?? ""
        case .completed:
            title = String(localized: "\(agent) finished")
            body = last ?? p.body ?? ""
        case .failed:
            title = String(localized: "\(agent) stopped with an error")
            body = p.body ?? last ?? ""
        case .chief:
            // Chief's reply reads as a message, as the app shows it: "Chief", its
            // text without Markdown syntax, no session or Mac line (duplicate
            // Chief notifications, 2026-10-30).
            self.init(title: String(localized: "Chief"), body: PushPlainText(markdown: p.body ?? last ?? "").text)
            return
        case .terminal:
            // A program chooses its own title: it never stands where an agent's banner would (review L6).
            title = place.map { String(localized: "Terminal · \($0)") } ?? String(localized: "Terminal")
            body = [p.title, p.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
        }
        let subtitle = p.kind == .permission ? place : place.map { "\($0) · \(mac)" } ?? mac
        self.init(title: title, subtitle: subtitle, body: body)
    }
}
