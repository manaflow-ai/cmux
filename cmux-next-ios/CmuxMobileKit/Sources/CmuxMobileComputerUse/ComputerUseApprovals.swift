public import CmuxDeviceHub
public import CmuxMobileNotifications
public import Foundation
public import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "computer-use")

/// An answer to a Mac's Computer Use question, on its way back over that Mac's
/// link or the reply mailbox (docs/computer-use-approvals.md, "Phone wire (macOS)").
/// An Allow is signed with the phone's approval key, which asks for Face ID itself.
public struct ComputerUseMacAnswer: Sendable, Equatable {
    public var macID: String
    public var macName: String?
    public var digest: String
    public var decision: ComputerUseDecision
    /// The line the Face ID sheet shows (Allows only).
    public var reason: String

    public init(macID: String, macName: String?, digest: String, decision: ComputerUseDecision, reason: String) {
        self.macID = macID
        self.macName = macName
        self.digest = digest
        self.decision = decision
        self.reason = reason
    }

    /// Why an answer did not reach the Mac.
    public enum Failure: Error, Equatable, Sendable {
        /// Face ID was cancelled: nothing was signed or sent.
        case cancelled
        /// The Mac (or its host) refused it, with what to say.
        case refused(String)
        /// Neither the link nor the mailbox reached the Mac.
        case unreachable
    }
}

/// This iPhone as an approver of Computer Use questions (docs/computer-use-approvals.md,
/// "Collectors"; docs/device-hub/PROTOCOL.md, "Computer Use approvals").
///
/// From the device hub, questions arrive as a push (`CMUX_COMPUTER_USE_APPROVAL`), over
/// the User DO socket (`approval.request`) or from `GET /v1/approvals` after a reconnect.
/// Whatever brought one, the phone fetches it again from the hub it is built with,
/// recomputes the digest from the request and refuses a mismatch, an expired or closed
/// one, or one this phone asked. From a Mac's app (`CMUX_MOBILE_COMPUTER_USE`) the push
/// carries the request itself; its digest is recomputed the same way. Only then does
/// the sheet show it or the phone sign an answer:
/// - Allow Once / Allow for This Session / Always Allow sign after Face ID (or the passcode),
///   with a key whose access control asks for it (hub: the device's approval key; Mac: the
///   phone's approval key), so no code in the app signs an Allow without the person;
/// - Deny signs with the device key (hub) or goes unsigned (Mac) without it.
@MainActor @Observable
public final class ComputerUseApprovals {
    public static let shared = ComputerUseApprovals()

    /// What the sheet shows.
    public struct Sheet: Identifiable, Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            /// Fetching and checking the question.
            case loading
            /// The question, waiting for an answer.
            case ready
            /// Asking for Face ID, signing and sending this choice.
            case deciding(ComputerUseChoice)
            /// The asking machine took the answer.
            case decided(ComputerUseDecision)
            /// Not answerable here, or answering failed; the message says why.
            case failed(String)
        }

        public var id: String
        public var review: ComputerUseApprovalReview?
        public var phase: Phase
    }

    /// The question on screen, nil when none.
    public private(set) var sheet: Sheet?

    /// Where the app's hub is and how this phone reaches it and its Macs.
    public struct Environment {
        /// The hub this build talks to; a push naming another is ignored.
        public var hubURL: URL
        /// A client signed in as this phone: the running hub's, else one built for a cold background launch.
        public var client: @MainActor () async -> DeviceHubClient?
        /// Sends an answer to a Mac's question (link, else mailbox); throws ``ComputerUseMacAnswer/Failure``.
        public var answerMac: @MainActor (ComputerUseMacAnswer) async throws -> Void
        /// Face ID or the passcode for a hub Allow, unlocking this phone's approval key
        /// (Secure Enclave, `.userPresence`) for one signature; throws when the person cancels or fails.
        public var authorizeApproval: @MainActor (ComputerUseApprovalKey, String) async throws -> ComputerUseApprovalAuthorization
        /// Whether Face ID can show now: the app is active and its own lock is open.
        public var isInteractive: @MainActor () -> Bool
        /// Removes a question's delivered notification by its request identifier.
        public var removeNotification: @MainActor (String) -> Void
        /// The APNs topic (the bundle id) and environment of this build.
        public var pushTopic: String?
        public var pushEnvironment: DeviceHubPushEnvironment
        public var now: @Sendable () -> Date

        public init(hubURL: URL, client: @escaping @MainActor () async -> DeviceHubClient?,
                    answerMac: @escaping @MainActor (ComputerUseMacAnswer) async throws -> Void = { _ in throw ComputerUseMacAnswer.Failure.unreachable },
                    authorizeApproval: @escaping @MainActor (ComputerUseApprovalKey, String) async throws -> ComputerUseApprovalAuthorization = {
                        try await $0.authorize(reason: $1)
                    },
                    isInteractive: @escaping @MainActor () -> Bool = { true },
                    removeNotification: @escaping @MainActor (String) -> Void = { _ in },
                    pushTopic: String? = Bundle.main.bundleIdentifier, pushEnvironment: DeviceHubPushEnvironment = .production,
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.hubURL = hubURL
            self.client = client
            self.answerMac = answerMac
            self.authorizeApproval = authorizeApproval
            self.isInteractive = isInteractive
            self.removeNotification = removeNotification
            self.pushTopic = pushTopic
            self.pushEnvironment = pushEnvironment
            self.now = now
        }
    }

    @ObservationIgnored public var environment: Environment?
    /// The hub whose socket this phone follows (weak: the Screen Sharing service owns it).
    @ObservationIgnored private weak var hub: DeviceHub?
    /// A choice from a notification button that waits until Face ID can show.
    @ObservationIgnored private var waitingChoice: (id: String, choice: ComputerUseChoice)?
    /// Questions the person closed or answered here: never shown again from a list.
    @ObservationIgnored private var handled: Set<String> = []
    @ObservationIgnored private var deviceToken: String?
    /// What the hub last accepted for this phone's push registration.
    @ObservationIgnored private var sentPush: String?

    public init(environment: Environment? = nil) {
        self.environment = environment
    }

    // MARK: Entry points

    /// A tap on a hub question's notification, or one of its buttons. Returns once a
    /// background Deny was sent or failed (iOS keeps the app awake until then).
    public func handle(_ notice: ComputerUseApprovalNotice, action: ComputerUseApprovalAction?, requireFaceID: Bool) async {
        guard let environment else { return }
        guard notice.isFrom(environment.hubURL) else {
            log.error("computer use push names another hub; ignored")
            return
        }
        if let action, !action.opensApp(requireFaceID: requireFaceID) {
            await denyHubInBackground(notice.approvalID)
            return
        }
        await open(notice.approvalID, choice: action.map(ComputerUseChoice.init))
    }

    /// A tap on a Mac's question (kind `computer_use`), or one of its buttons. `actionable`
    /// is the trust gate's word: a push that may not act (an unsealed one from a Mac that
    /// seals, a stale one) shows nothing to answer.
    public func handle(macPayload payload: PushPayload, action: ComputerUseApprovalAction?, actionable: Bool, requireFaceID: Bool) async {
        guard let environment else { return }
        let review: ComputerUseApprovalReview
        do {
            review = try ComputerUseApprovalReview(payload: payload, now: environment.now())
        } catch {
            show(failure: Self.message(for: error), id: payload.eventId ?? "computer-use")
            return
        }
        guard actionable else {
            show(failure: String(localized: "Answer this request on \(review.machineName)."), id: review.id)
            return
        }
        if let action, !action.opensApp(requireFaceID: requireFaceID) {
            if action == .deny { await answerMacInBackground(review) }
            return
        }
        await present(review, choice: action.map(ComputerUseChoice.init))
    }

    /// Shows a hub question: fetched from the hub and checked first. With `choice` (an
    /// Allow button on the notification) the answer is signed once Face ID can show.
    public func open(_ id: String, choice: ComputerUseChoice? = nil) async {
        guard let environment else { return }
        guard isFree(for: id) else { return }
        sheet = Sheet(id: id, review: nil, phase: .loading)
        guard let client = await environment.client() else {
            fail(id, String(localized: "Sign in to cmux to answer this request."))
            return
        }
        let review: ComputerUseApprovalReview
        do {
            review = try await fetchReview(id, client: client, environment: environment)
        } catch {
            fail(id, Self.message(for: error))
            return
        }
        guard sheet?.id == id else { return }
        await present(review, choice: choice)
    }

    /// The app became active, or its lock opened: a choice that waited for Face ID runs.
    public func interactivityChanged() {
        runWaitingChoice()
        presentNextIfIdle()
    }

    /// An answer from the sheet.
    public func choose(_ choice: ComputerUseChoice) {
        guard let sheet, let review = sheet.review, sheet.phase == .ready, review.offers(choice) else { return }
        Task { await decide(review, choice: choice) } // task-owner: one answer; the sheet shows its phase
    }

    /// The sheet closed. A question left unanswered stays answerable from its notification or the list.
    public func dismiss() {
        if let sheet { handled.insert(sheet.id) }
        sheet = nil
        waitingChoice = nil
        presentNextIfIdle()
    }

    /// One question at a time: another waits until this one is answered or closed.
    private func isFree(for id: String) -> Bool {
        guard let sheet, sheet.id != id else { return true }
        return Self.isFinished(sheet.phase)
    }

    /// Shows `review`; a notification button's `choice` is answered now when Face ID can
    /// show, else once the app is active and unlocked (``interactivityChanged()``).
    private func present(_ review: ComputerUseApprovalReview, choice: ComputerUseChoice?) async {
        guard isFree(for: review.id) else { return }
        sheet = Sheet(id: review.id, review: review, phase: .ready)
        guard let choice, review.offers(choice) else { return }
        if environment?.isInteractive() ?? false {
            await decide(review, choice: choice)
        } else {
            waitingChoice = (review.id, choice)
        }
    }

    private func show(failure message: String, id: String) {
        guard isFree(for: id) else { return }
        sheet = Sheet(id: id, review: nil, phase: .failed(message))
    }

    // MARK: Hub

    /// Follows `hub`'s questions (socket pushes and the list read on every connect)
    /// and gives it this phone's push token. Call it each time the hub is ready.
    public func follow(_ hub: DeviceHub) {
        self.hub = hub
        hub.followsApprovals = true
        hub.onApprovalPush = { [weak self] push in self?.route(push) }
        observeList(hub)
        Task { await hub.refreshApprovals() } // task-owner: one list read when the hub becomes ready
        syncPush()
    }

    /// The hub went away (sign-out).
    public func unfollow() {
        hub?.onApprovalPush = nil
        hub = nil
        sheet = nil
        waitingChoice = nil
        handled = []
        sentPush = nil
    }

    func route(_ push: DeviceHubPush) {
        switch push {
        case let .approvalRequest(approval):
            if sheet == nil, !handled.contains(approval.id), environment?.isInteractive() ?? false {
                Task { await open(approval.id) } // task-owner: fetch and check one question before showing it
            }
        case let .approvalClosed(id, state, _):
            closed(id, state: state)
        case let .approvalDecided(decided):
            closed(decided.id, state: .decided)
        default:
            break
        }
    }

    /// Another device answered, the machine cancelled, or it expired: the question goes.
    func closed(_ id: String, state: ComputerUseApprovalState?) {
        environment?.removeNotification(ComputerUseApprovalNotice.notificationIdentifier(approvalID: id))
        if waitingChoice?.id == id { waitingChoice = nil }
        guard let sheet, sheet.id == id, !Self.isFinished(sheet.phase) else { return }
        let message = switch state {
        case .expired: String(localized: "This request has expired.")
        case .cancelled: String(localized: "The agent stopped asking.")
        case .decided, .pending, nil: String(localized: "This request was answered on another device.")
        }
        self.sheet?.phase = .failed(message)
    }

    private func observeList(_ hub: DeviceHub) {
        let ids = withObservationTracking { hub.approvals.map(\.id) } onChange: { [weak self, weak hub] in
            Task { @MainActor [weak self, weak hub] in
                guard let self, let hub, self.hub === hub else { return }
                observeList(hub)
            }
        }
        if let sheet, case .hub? = sheet.review?.source, !ids.contains(sheet.id), sheet.phase == .ready {
            // Dropped from the hub's list without a close push (a refetch after a reconnect).
            closed(sheet.id, state: nil)
        }
        presentNextIfIdle()
    }

    private func presentNextIfIdle() {
        guard sheet == nil, environment?.isInteractive() ?? false,
              let next = hub?.approvals.first(where: { !handled.contains($0.id) }) else { return }
        Task { await open(next.id) } // task-owner: fetch and check the next question before showing it
    }

    // MARK: Deciding

    private func runWaitingChoice() {
        guard let waiting = waitingChoice, let environment, environment.isInteractive(),
              let sheet, sheet.id == waiting.id, sheet.phase == .ready, let review = sheet.review else { return }
        waitingChoice = nil
        Task { await decide(review, choice: waiting.choice) } // task-owner: one answer from a notification button
    }

    func decide(_ review: ComputerUseApprovalReview, choice: ComputerUseChoice) async {
        guard let environment else { return }
        let id = review.id
        sheet?.phase = .deciding(choice)
        do {
            switch review.source {
            case .hub:
                try await decideOnHub(review, choice: choice, environment: environment)
            case let .mac(mac, name):
                // The approval key asks for Face ID itself before it signs an Allow.
                try await environment.answerMac(ComputerUseMacAnswer(macID: mac, macName: name, digest: review.digest, decision: choice.decision,
                                                                     reason: review.userPresenceReason(for: choice)))
            }
            handled.insert(id)
            if sheet?.id == id { sheet?.phase = .decided(choice.decision) }
            log.info("computer use: answered \(choice.decision.rawValue, privacy: .public)")
        } catch ComputerUseMacAnswer.Failure.cancelled {
            // Cancelled Face ID: the question stays, nothing was signed.
            if sheet?.id == id { sheet?.phase = .ready }
        } catch {
            fail(id, Self.message(for: error))
        }
    }

    private func decideOnHub(_ review: ComputerUseApprovalReview, choice: ComputerUseChoice, environment: Environment) async throws {
        let id = review.id
        guard let client = await environment.client() else { throw ComputerUseMacAnswer.Failure.unreachable }
        var authorization: ComputerUseApprovalAuthorization?
        if choice.needsUserPresence {
            // An Allow is signed only by the approval key, whose access control itself asks for Face ID.
            guard let key = client.identity.approvalKey else { throw DeviceHubError.server(status: 403, code: .approvalKeyRequired, message: "") }
            do {
                authorization = try await environment.authorizeApproval(key, review.userPresenceReason(for: choice))
            } catch {
                throw ComputerUseMacAnswer.Failure.cancelled
            }
        }
        // Fetched and checked again right before signing: it may have closed meanwhile.
        let fresh = try await fetchReview(id, client: client, environment: environment)
        guard fresh.offers(choice) else { throw ComputerUseApproval.Refusal.notPending }
        _ = try await client.decide(id: id, decision: choice.decision, digest: fresh.digest, authorization: authorization)
        hub?.forgetApproval(id)
        environment.removeNotification(ComputerUseApprovalNotice.notificationIdentifier(approvalID: id))
    }

    /// Deny from the lock screen: fetched, checked, signed and sent without opening the app.
    private func denyHubInBackground(_ id: String) async {
        guard let environment, let client = await environment.client() else {
            log.error("computer use deny: not signed in")
            return
        }
        do {
            let review = try await fetchReview(id, client: client, environment: environment)
            _ = try await client.decide(id: id, decision: .deny, digest: review.digest)
            handled.insert(id)
            hub?.forgetApproval(id)
            log.info("computer use: denied from the notification")
        } catch {
            log.error("computer use deny failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deny from a Mac question's notification: unsigned, over the link or the mailbox.
    private func answerMacInBackground(_ review: ComputerUseApprovalReview) async {
        guard let environment, case let .mac(mac, name) = review.source else { return }
        do {
            try await environment.answerMac(ComputerUseMacAnswer(macID: mac, macName: name, digest: review.digest, decision: .deny,
                                                                 reason: review.userPresenceReason(for: .deny)))
            handled.insert(review.id)
        } catch {
            log.error("computer use deny to the Mac failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func fetchReview(_ id: String, client: DeviceHubClient, environment: Environment) async throws -> ComputerUseApprovalReview {
        let approval = try await client.approval(id: id)
        guard approval.id == id else { throw ComputerUseApproval.Refusal.digestMismatch }
        return try ComputerUseApprovalReview(approval: approval, thisDeviceID: client.identity.id, now: environment.now())
    }

    private func fail(_ id: String, _ message: String) {
        guard sheet?.id == id else { return }
        sheet?.phase = .failed(message)
    }

    static func isFinished(_ phase: Sheet.Phase) -> Bool {
        switch phase {
        case .decided, .failed: true
        case .loading, .ready, .deciding: false
        }
    }

    /// What the sheet says for a failure.
    static func message(for error: any Error) -> String {
        if let refusal = error as? ComputerUseApproval.Refusal { return refusal.message }
        if let failure = error as? ComputerUseMacAnswer.Failure {
            switch failure {
            case let .refused(message): return message
            case .unreachable: return String(localized: "cmux couldn't reach your devices. Try again.")
            case .cancelled: return String(localized: "Face ID was cancelled.")
            }
        }
        switch (error as? DeviceHubError)?.code {
        case .approvalNotPending?: return ComputerUseApproval.Refusal.notPending.message
        case .approvalExpired?: return ComputerUseApproval.Refusal.expired.message
        case .selfApproval?: return ComputerUseApproval.Refusal.ownRequest.message
        case .digestMismatch?: return ComputerUseApproval.Refusal.digestMismatch.message
        case .notFound?: return String(localized: "This request is no longer available.")
        case .alwaysNotAllowed?: return String(localized: "That device doesn't allow Always Allow from this iPhone.")
        case .approvalKeyRequired?, .approvalKeyMismatch?:
            return String(localized: "This iPhone can't approve yet. Open cmux and sign in again, then try again.")
        default: return String(localized: "cmux couldn't reach your devices. Try again.")
        }
    }

    // MARK: Push registration

    /// The APNs device token (app delegate): the hub gets it alongside the service's registration.
    public func didRegister(deviceToken: Data) {
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        syncPush()
    }

    private func syncPush() {
        guard let hub, hub.status == .ready, let token = deviceToken, let environment, let topic = environment.pushTopic else { return }
        let key = [hub.identity.id, token, topic, environment.pushEnvironment.rawValue].joined(separator: "|")
        guard key != sentPush else { return }
        let client = hub.client, pushEnvironment = environment.pushEnvironment
        sentPush = key
        Task { [weak self] in // task-owner: one registration call per changed token, device or build
            do {
                let answer = try await client.registerPush(token: token, topic: topic, environment: pushEnvironment)
                log.info("device hub push registered: \(answer.registered, privacy: .public), hub sends pushes: \(answer.configured, privacy: .public)")
            } catch {
                // A topic the hub does not list (a tagged build) is refused: questions still reach the app over its socket.
                log.error("device hub push registration failed: \(String(describing: error), privacy: .public)")
                if self?.sentPush == key { self?.sentPush = nil }
            }
        }
    }

    /// Sign-out: the hub forgets this phone's token while the account can still reach it.
    public func forgetPush() async {
        guard sentPush != nil, let hub, let environment, let topic = environment.pushTopic else { return }
        sentPush = nil
        do {
            _ = try await hub.client.registerPush(token: nil, topic: topic, environment: environment.pushEnvironment)
        } catch {
            log.error("device hub push unregister failed: \(String(describing: error), privacy: .public)")
        }
    }
}
