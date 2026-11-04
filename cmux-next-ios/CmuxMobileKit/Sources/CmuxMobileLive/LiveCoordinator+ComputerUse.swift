#if os(iOS)
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "computer-use")

/// Answers to a Mac's Computer Use question (docs/computer-use-approvals.md,
/// "Phone wire (macOS)"): an Allow signed with the approval key (Face ID), sent
/// over the Mac's link (`cu-approval-answer` on the daemon channel), else through
/// the reply mailbox. A Deny goes unsigned.
extension LiveCoordinator {
    /// A signed (Allow) or unsigned (Deny) answer, ready for the link or the mailbox.
    public struct ComputerUseAnswer: Sendable, Equatable {
        public var mac: String
        public var macName: String?
        public var digest: String
        /// `once`, `session`, `always` or `deny`.
        public var decision: String
        /// Unix seconds; the host takes `now <= expiresAt <= now + 300`.
        public var expiresAt: Int
        /// Lowercase hex raw r||s over ``ComputerUseAnswer/signedMessage(phone:digest:decision:expiresAt:)``; nil for Deny.
        public var signature: String?
        /// The phone's link device id (the approver).
        public var phone: String

        /// `cmux-cu-phone-approval-v1 \0 phone \0 digest \0 decision \0 expiresAt`.
        public static func signedMessage(phone: String, digest: String, decision: String, expiresAt: Int) -> Data {
            PushSeal.joined("cmux-cu-phone-approval-v1", [phone, digest, decision, String(expiresAt)])
        }

        /// The daemon channel's `cu-approval-answer` params (the link names the phone).
        public var linkParams: [String: Any] {
            var params: [String: Any] = ["digest": digest, "decision": decision, "expires_at": expiresAt]
            if let signature { params["signature"] = signature }
            return params
        }
    }

    /// How long an answer's signature stays valid (the host takes at most 300 s).
    public static let computerUseAnswerLifetime: TimeInterval = 120

    /// Signs `decision` for `digest` with the approval key (Face ID first) when it is an
    /// Allow. Throws `PushReplyFailure` (`cancelled` when Face ID was cancelled).
    public func signComputerUseAnswer(mac: String, macName: String?, digest: String, decision: String, reason: String,
                                      now: Date = Date()) async throws -> ComputerUseAnswer {
        guard let pairing else { throw PushReplyFailure(reason: .refused(String(localized: "Pair this iPhone with \(macName ?? String(localized: "your Mac")) first."))) }
        let expiresAt = Int(now.timeIntervalSince1970 + Self.computerUseAnswerLifetime)
        var answer = ComputerUseAnswer(mac: mac, macName: macName, digest: digest, decision: decision, expiresAt: expiresAt,
                                       signature: nil, phone: pairing.phoneID)
        guard decision != "deny" else { return answer }
        do {
            let sign = try await pairing.keys.authorizeApproval(reason: reason)
            let message = ComputerUseAnswer.signedMessage(phone: pairing.phoneID, digest: digest, decision: decision, expiresAt: expiresAt)
            answer.signature = PushSignature.hex(try sign(message))
        } catch PhoneKeys.Failure.cancelled {
            throw PushReplyFailure(reason: .cancelled)
        } catch {
            throw PushReplyFailure(reason: .refused((error as? PhoneKeys.Failure)?.message ?? String(describing: error)))
        }
        return answer
    }

    /// Sends `answer` over its Mac's link. Throws `PushReplyFailure` (`unreachable`
    /// when the link did not come up within `budget`: the mailbox may still reach it).
    public func deliverComputerUseAnswer(_ answer: ComputerUseAnswer, budget: Duration = LiveCoordinator.pushReplyBudget) async throws {
        touch(answer.mac)
        let mac = answer.mac
        guard await waitUntil(within: budget, { [weak self] in self?.sessions[mac]?.workspaces.daemon != nil }),
              let daemon = sessions[mac]?.workspaces.daemon else {
            throw PushReplyFailure(reason: .unreachable)
        }
        let data: Data
        do {
            data = try await daemon.request("cu-approval-answer", params: answer.linkParams)
        } catch let error as LinkError {
            log.error("computer use answer failed on the link: \(error.message, privacy: .public)")
            throw PushReplyFailure(reason: .unreachable)
        }
        if let refusal = Self.computerUseRefusal(data) {
            throw PushReplyFailure(reason: .refused(refusal))
        }
        log.info("computer use answer delivered over the link")
    }

    /// Sends `answer` through the service's mailbox, sealed to its Mac's box key and
    /// signed by this phone's identity key. Throws `PushReplyFailure`.
    public func deliverComputerUseAnswerViaMailbox(_ answer: ComputerUseAnswer, now: Date = Date()) async throws -> MailboxOutcome {
        guard let pairing, let push = pairing.push, let trust = push.trust(), trust.user == userID, trust.phone == pairing.phoneID,
              let mac = trust.macs[answer.mac.lowercased()] else {
            throw PushReplyFailure(reason: .unreachable)
        }
        let boxKey: String
        do {
            boxKey = try MailboxReply.trustedBoxKey(mac, macID: answer.mac, pinnedIdentity: pairing.pins.key(for: answer.mac))
        } catch {
            throw PushReplyFailure(reason: .unreachable)
        }
        let id = UUID().uuidString.lowercased()
        let sealed: String
        do {
            let mailbox = try MailboxReply(computerUse: answer.digest, decision: answer.decision, mac: answer.mac, id: id,
                                           phone: pairing.phoneID, nonce: MailboxReply.newNonce(), now: now,
                                           approval: answer.signature.map { signature in
                                               .object(["approver": .string(pairing.phoneID), "expiresAt": .int(Int64(answer.expiresAt)),
                                                        "signature": .string(signature)])
                                           },
                                           expiresAt: answer.signature == nil ? nil : answer.expiresAt)
            sealed = try mailbox.sealed(signature: try pairing.keys.signIdentity(mailbox.signedMessage), boxKey: boxKey)
        } catch {
            throw PushReplyFailure(reason: .unreachable)
        }
        do {
            let delivered = try await api.postMailbox(macID: answer.mac, id: id, from: pairing.phoneID, sealed: sealed)
            log.info("computer use answer sent through the mailbox (\(delivered ? "delivered" : "queued", privacy: .public))")
            return delivered ? .delivered : .queued
        } catch {
            log.error("computer use mailbox post failed: \(String(describing: error), privacy: .public)")
            throw PushReplyFailure(reason: .unreachable)
        }
    }

    /// The host's refusal of a `cu-approval-answer`, said for a person; nil when it took it.
    nonisolated static func computerUseRefusal(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = object["error"]
        guard error != nil || object["ok"] as? Bool == false else { return nil }
        let code = ((error as? [String: Any])?["code"] as? String) ?? (error as? String) ?? (object["reason"] as? String)
        return computerUseRefusalMessage(code)
    }

    /// What the phone says for the host's refusal codes.
    nonisolated static func computerUseRefusalMessage(_ code: String?) -> String {
        switch code {
        case "not_pending": String(localized: "This request was already answered or has ended.")
        case "expired": String(localized: "Your answer arrived too late.")
        case "not_paired": String(localized: "This iPhone isn't paired with that Mac any more.")
        case "bad_signature": String(localized: "Your Mac couldn't check this iPhone's signature.")
        default: String(localized: "Your Mac didn't accept the answer.")
        }
    }
}
#endif
