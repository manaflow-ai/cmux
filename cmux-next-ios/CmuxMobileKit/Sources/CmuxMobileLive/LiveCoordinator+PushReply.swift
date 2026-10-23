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
                let blocks = AcpmuxSessionSource.promptBlocks(text: text, attachments: Self.attachments(attachments))
                _ = try await hub.request("session/prompt", .object([
                    "sessionId": .string(sessionID), "prompt": .array(blocks),
                    "_meta": .object(["acpmux": .object(["promptId": .string(promptID), "steer": .bool(false), "resend": .bool(true)])]),
                ]))
            case .chief:
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
        let images = Self.attachments(names).compactMap { attachment -> ConversationComposeImage? in
            guard let data = attachment.data, let mime = attachment.imageMIMEType, let size = UIImage(data: data)?.size else { return nil }
            return ConversationComposeImage(data: data, width: Int(size.width), height: Int(size.height), mimeType: mime)
        }
        chief.send(ConversationComposeMessage(text: text, images: images))
    }

    /// The outbox attachments a reply names (images and files the content extension saved).
    static func attachments(_ names: [String]) -> [AgentAttachment] {
        guard !names.isEmpty, let outbox = PushOutbox(group: .current()) else { return [] }
        return names.compactMap { name in
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
