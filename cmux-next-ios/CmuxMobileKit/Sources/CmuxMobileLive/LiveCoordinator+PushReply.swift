#if os(iOS)
import CmuxAgentQuestion
import CmuxConversationCore
import CmuxMobileAgentChat
import CmuxMobileChief
import CmuxMobileNotifications
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "push")

/// Notification replies over the Mac's own link (verify/rich-push.md, "Reply
/// delivery"): the link to the reply's Mac opens (one link per Mac), the
/// prompt it answers is read again, and the reply goes out through the same
/// hub calls the chat and the Feed use.
extension LiveCoordinator {
    /// How long a reply waits for its Mac's link before it fails.
    public static let pushReplyBudget: Duration = .seconds(4)

    public struct PushReplyFailure: Error, Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// The link did not come up within the budget: Retry can help.
            case unreachable
            /// The Mac refused or the prompt moved on: Retry won't help.
            case refused(String)
            /// Face ID was cancelled.
            case cancelled
        }

        public var reason: Reason

        public var isRetryable: Bool { reason == .unreachable }
    }

    /// Delivers `reply` to its Mac. Throws `PushReplyFailure`.
    public func deliver(_ reply: PushReply, budget: Duration = LiveCoordinator.pushReplyBudget) async throws {
        touch(reply.mac)
        if reply.kind == .chief {
            try await deliverToChief(reply, budget: budget)
            return
        }
        // A terminal notification's reply (PR B): input to that terminal.
        if reply.kind == .terminal {
            try await deliverToTerminal(reply, budget: budget)
            return
        }
        // A terminal agent's question (it has a tab, no acpmux permission): typed into its terminal.
        if reply.kind == .question, reply.permissionId == nil, let tabID = reply.tabId {
            try await deliverToTerminal(reply, tabID: tabID, budget: budget)
            return
        }
        // The Mac's session appears once the account's team and Macs are known (a
        // cold launch learns them first), and its chats once the link is served.
        let mac = reply.mac
        guard await waitUntil(within: budget, { [weak self] in self?.sessions[mac]?.acpmux.isReady == true }),
              let hub = sessions[mac]?.acpmux else {
            log.error("push reply: no link to that Mac within the budget")
            throw PushReplyFailure(reason: .unreachable)
        }
        let pending = try await pendingPrompt(reply, hub: hub)
        let plan: PushReplyPlan
        do {
            plan = try PushReplyPlan.make(reply, pending: pending)
        } catch let refusal as PushReplyPlan.Refusal {
            throw PushReplyFailure(reason: .refused(refusal.message))
        }
        do {
            switch plan {
            case .answer(let question, let answer):
                try await hub.answer(question, with: answer)
            case .decline(let question):
                try await hub.decline(question)
            case .respond(let sessionID, let permissionID, let optionID):
                try await hub.respond(sessionID: sessionID, permissionID: permissionID, optionID: optionID)
            case .prompt(let sessionID, let text, let attachments, let promptID):
                let blocks = AcpmuxSessionSource.promptBlocks(text: text, attachments: await Self.attachments(attachments))
                _ = try await hub.request("session/prompt", .object([
                    "sessionId": .string(sessionID), "prompt": .array(blocks),
                    "_meta": .object(["acpmux": .object(["promptId": .string(promptID), "steer": .bool(false), "resend": .bool(true)])]),
                ]))
            case .chief, .terminal:
                break
            }
        } catch is AcpmuxHub.ApprovalCancelled {
            throw PushReplyFailure(reason: .cancelled)
        } catch let error as LinkError {
            log.error("push reply failed on the link: \(error.message, privacy: .public)")
            throw PushReplyFailure(reason: .unreachable)
        } catch {
            if (error as? AcpmuxConnection.RPCError)?.message.hasPrefix("no pending permission") == true {
                throw PushReplyFailure(reason: .refused(String(localized: "This was already answered.")))
            }
            throw PushReplyFailure(reason: .refused(AcpmuxSessionSource.message(error)))
        }
        log.info("push reply delivered (\(reply.kind.rawValue, privacy: .public))")
    }

    /// The prompt an answer is for, as acpmux has it now; nil when it is no
    /// longer pending. Nil for a text reply (it answers no prompt).
    private func pendingPrompt(_ reply: PushReply, hub: AcpmuxHub) async throws -> AgentSessionEvent? {
        guard case .text = reply.action else {
            guard let sessionID = reply.sessionId, let permissionID = reply.permissionId else { return nil }
            let info: JSONValue
            do {
                info = try await hub.request("_acpmux/info", .object(["sessionId": .string(sessionID)]))
            } catch {
                throw PushReplyFailure(reason: .unreachable)
            }
            guard let pending = info["pending"]?.arrayValue?.first(where: { $0["permissionId"]?.stringValue == permissionID }),
                  let request = pending["request"] else { return nil }
            return AcpmuxRecords(sessionID: sessionID).permission(permissionID, request: request)
        }
        return nil
    }

    /// A Chief reply: Chief runs on the focused Mac's link, so the reply's Mac
    /// becomes the focus first, then the message goes once Chief is connected.
    private func deliverToChief(_ reply: PushReply, budget: Duration) async throws {
        guard case .text(let text, let names) = reply.action else { throw PushReplyFailure(reason: .refused("")) }
        if focusedMacID != reply.mac { select(macID: reply.mac) }
        let chief = ChiefSession.shared
        let mac = reply.mac
        guard await waitUntil(within: budget, { [weak self] in self?.chiefMacID == mac && chief.isConnected }) else {
            throw PushReplyFailure(reason: .unreachable)
        }
        let images = await Self.attachments(names).compactMap { attachment -> ConversationComposeImage? in
            guard let data = attachment.data, let mime = attachment.imageMIMEType, let size = UIImage(data: data)?.size else { return nil }
            return ConversationComposeImage(data: data, width: Int(size.width), height: Int(size.height), mimeType: mime)
        }
        chief.send(ConversationComposeMessage(text: text, images: images))
    }

    /// Send Message… to the Chief about a workspace or a tab of `macID`: Chief runs on the
    /// focused Mac's link, so that Mac becomes the focus first, and the message goes only once
    /// its Chief is connected (never to the Chief of the Mac that was focused). False when the
    /// Mac can't be reached within `budget`; nothing was sent then.
    public func sendToChief(_ text: String, on macID: String, budget: Duration = .seconds(20)) async -> Bool {
        guard canLink(macID: macID) else { return false }
        if focusedMacID != macID { select(macID: macID) }
        let chief = ChiefSession.shared
        guard await waitUntil(within: budget, { [weak self] in self?.chiefMacID == macID && chief.isConnected }) else { return false }
        chief.send(text: text)
        return true
    }

    /// Text into the terminal that posted the notification, over the Mac's
    /// `daemon` channel (`notification-reply`; the Mac's policy allows only
    /// that notification and text).
    private func deliverToTerminal(_ reply: PushReply, budget: Duration) async throws {
        let plan: PushReplyPlan
        do {
            plan = try PushReplyPlan.make(reply, pending: nil)
        } catch let refusal as PushReplyPlan.Refusal {
            throw PushReplyFailure(reason: .refused(refusal.message))
        }
        guard case .terminal(let notification, let text) = plan else { throw PushReplyFailure(reason: .refused("")) }
        let mac = reply.mac
        guard await waitUntil(within: budget, { [weak self] in self?.sessions[mac]?.workspaces.daemon != nil }),
              let daemon = sessions[mac]?.workspaces.daemon else {
            throw PushReplyFailure(reason: .unreachable)
        }
        let data: Data
        do {
            data = try await daemon.request("notification-reply",
                                            params: PushReplyPlan.terminalRequest(notification: notification, text: text, replyID: reply.id))
        } catch let error as LinkError {
            log.error("terminal reply failed on the link: \(error.message, privacy: .public)")
            throw PushReplyFailure(reason: .unreachable)
        }
        if case .refused(let message) = PushReplyPlan.terminalAnswer(data) {
            throw PushReplyFailure(reason: .refused(message))
        }
        log.info("terminal reply delivered")
    }

    // MARK: The mailbox (PR B)

    /// How long a mailbox Allow's acpmux signature stays valid: acpmux takes
    /// at most 300 s, less a margin for the Mac's clock. A reply that waits
    /// longer in the mailbox is refused by acpmux, and the phone says so.
    static let mailboxApprovalLifetime: TimeInterval = 290

    /// What the mailbox did with a reply.
    public enum MailboxOutcome: Equatable, Sendable {
        /// The service holds it and the Mac's host was online (it has it now).
        case delivered
        /// The service holds it until the Mac's host connects (at most 10 minutes).
        case queued
    }

    /// Sends `reply` through the service's mailbox, sealed to its Mac's box
    /// key and signed by this phone's identity key (PROTOCOL.md "Reply
    /// mailbox"). An Allow is signed by the approval key first (Face ID).
    /// Throws `PushReplyFailure` (`unreachable` when the Mac has no box key or
    /// the service is out of reach, `refused` when the reply can't go this way).
    public func deliverViaMailbox(_ reply: PushReply, now: Date = Date()) async throws -> MailboxOutcome {
        guard let pairing, let push = pairing.push, let trust = push.trust(), trust.user == userID, trust.phone == pairing.phoneID,
              let mac = trust.macs[reply.mac.lowercased()] else {
            throw PushReplyFailure(reason: .unreachable)
        }
        let boxKey: String
        do {
            boxKey = try MailboxReply.trustedBoxKey(mac, macID: reply.mac, pinnedIdentity: pairing.pins.key(for: reply.mac))
        } catch {
            log.error("mailbox: the Mac's box key doesn't check against its pinned key")
            throw PushReplyFailure(reason: .unreachable)
        }
        guard MailboxReply.supports(reply) else { throw PushReplyFailure(reason: .unreachable) }
        var approval: PushJSON?
        if case .allow(let optionID) = reply.action, let nonce = reply.decisionNonce, let instance = reply.personInstance,
           let session = reply.sessionId, let permission = reply.permissionId {
            let payload = ApprovalPayload(instance: instance, macDevice: reply.mac, approver: pairing.phoneID, session: session,
                                          permission: permission, option: optionID, nonce: nonce,
                                          expiresAt: Int(now.timeIntervalSince1970 + Self.mailboxApprovalLifetime))
            do {
                let sign = try await pairing.keys.authorizeApproval(reason: String(localized: "Allow this request on your Mac"))
                approval = Self.pushJSON(payload.meta(signature: try sign(payload.message)))
            } catch PhoneKeys.Failure.cancelled {
                throw PushReplyFailure(reason: .cancelled)
            } catch {
                throw PushReplyFailure(reason: .refused((error as? PhoneKeys.Failure)?.message ?? String(describing: error)))
            }
        }
        guard let lifetime = Self.mailboxLifetime(reply, now: now) else {
            throw PushReplyFailure(reason: .refused(String(localized: "This reply is too old to send. Open the chat to answer again.")))
        }
        let sealed: String
        do {
            let mailbox = try MailboxReply(reply: reply, phone: pairing.phoneID, nonce: MailboxReply.newNonce(),
                                           now: Self.mailboxIssuedAt(reply, now: now), approval: approval,
                                           lifetime: lifetime)
            sealed = try mailbox.sealed(signature: try pairing.keys.signIdentity(mailbox.signedMessage), boxKey: boxKey)
        } catch MailboxReply.Failure.tooLong {
            throw PushReplyFailure(reason: .refused(String(localized: "That reply is too long to send without the link.")))
        } catch {
            throw PushReplyFailure(reason: .unreachable)
        }
        do {
            let delivered = try await api.postMailbox(macID: reply.mac, id: reply.id.uuidString.lowercased(), from: pairing.phoneID, sealed: sealed)
            log.info("push reply sent through the mailbox (\(delivered ? "delivered" : "queued", privacy: .public))")
            return delivered ? .delivered : .queued
        } catch let failure as LiveAPI.Failure where failure.status == 409 {
            // A retry of a reply the service already holds (its first blob): it is queued (PR B review 10).
            log.info("push reply already in the mailbox")
            return .queued
        } catch {
            log.error("mailbox post failed: \(String(describing: error), privacy: .public)")
            throw PushReplyFailure(reason: .unreachable)
        }
    }

    /// The mailbox's word on a reply; nil when the service can't say.
    public func mailboxState(of reply: PushReply) async -> LiveAPI.MailboxState? {
        try? await api.mailboxState(macID: reply.mac, id: reply.id.uuidString.lowercased())
    }

    /// What the Mac itself said about a mailbox reply (its signed ack, checked
    /// against its pinned key); nil while that is not known, or when the
    /// service's answer carries no valid signature (PR B security review M3).
    public func signedMailboxOutcome(_ reply: PushReply, state: LiveAPI.MailboxState) -> (applied: Bool, reason: String?)? {
        MailboxReply.verifiedOutcome(state: state.state, reason: state.reason, sig: state.sig, mac: reply.mac,
                                     id: reply.id.uuidString.lowercased(), pinnedIdentity: pairing?.pins.key(for: reply.mac))
    }

    /// A reply is valid from when the person made it, never longer than its
    /// first lifetime: a Retry re-seals with the same window, not a fresh one
    /// (PR B security review M1).
    nonisolated static func mailboxIssuedAt(_ reply: PushReply, now: Date) -> Date {
        min(reply.createdAt, now)
    }

    /// The reply's window from when it was made; nil once it is over (the Mac would refuse it).
    nonisolated static func mailboxLifetime(_ reply: PushReply, now: Date) -> TimeInterval? {
        let left = MailboxReply.lifetime - now.timeIntervalSince(mailboxIssuedAt(reply, now: now))
        return left >= 5 ? MailboxReply.lifetime : nil
    }

    /// `JSONValue` as the mailbox's canonical JSON (integers only: every number an approval carries is one).
    nonisolated static func pushJSON(_ value: JSONValue) -> PushJSON {
        switch value {
        case .null: .null
        case .bool(let b): .bool(b)
        case .number(let n): .int(Int64(n))
        case .string(let s): .string(s)
        case .array(let items): .array(items.map(pushJSON))
        case .object(let object): .object(object.mapValues(pushJSON))
        }
    }

    /// The outbox attachments a reply names (images and files the content extension saved).
    /// The App Group resolves and the files are read off the main thread.
    static func attachments(_ names: [String]) async -> [AgentAttachment] {
        guard !names.isEmpty, let outbox = PushOutbox(group: await PushAppGroup.resolved()) else { return [] }
        return await Task.detached(priority: .userInitiated) { readAttachments(names, in: outbox) }.value
    }

    nonisolated static func readAttachments(_ names: [String], in outbox: PushOutbox) -> [AgentAttachment] {
        names.compactMap { name in
            let safe = (name as NSString).lastPathComponent
            guard safe == name, let data = try? Data(contentsOf: outbox.attachments.appendingPathComponent(safe)) else { return nil }
            let image = AgentAttachment(kind: .image, name: safe, data: data)
            return image.imageMIMEType != nil ? image : AgentAttachment(kind: .file, name: safe, data: data)
        }
    }

    /// Waits until `condition` holds (re-read whenever what it reads changes),
    /// at most `budget`. No polling: Observation wakes it.
    public func waitUntil(within budget: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        if condition() { return true }
        return await ObservationWait(condition, clock: clock, budget: budget).value
    }
}

/// Resolves true once `condition` reads true (Observation re-arms after each
/// change), or false when `budget` ends or the task is cancelled.
@MainActor
public final class ObservationWait {
    private let condition: @MainActor () -> Bool
    private let clock: any Clock<Duration>
    private let budget: Duration
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?

    public init(_ condition: @escaping @MainActor () -> Bool, clock: any Clock<Duration> = ContinuousClock(), budget: Duration) {
        self.condition = condition
        self.clock = clock
        self.budget = budget
    }

    public var value: Bool {
        get async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    let clock = self.clock, budget = self.budget
                    self.timer = Task { [weak self] in
                        do { try await clock.sleep(for: budget) } catch { return }
                        self?.finish(false)
                    }
                    self.arm()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(false) }
            }
        }
    }

    private func arm() {
        guard continuation != nil else { return }
        let ready = withObservationTracking { condition() } onChange: { [weak self] in
            Task { @MainActor in self?.arm() }
        }
        if ready { finish(true) }
    }

    private func finish(_ result: Bool) {
        timer?.cancel()
        timer = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}
#endif
