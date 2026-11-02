import CmuxAgentQuestion
import CmuxConversationCore
import CmuxMobileArtifacts
import CmuxMobileModel
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Owns the Chief `ConversationStore` for the app's lifetime (the list row
/// and the open conversation share it) and mirrors what the list shows:
/// last message, unread count, typing.
@MainActor
@Observable
public final class ChiefSession {
    /// The Mac Chief: the Mac's Chief owner over the link (``ChiefDaemonBackend``),
    /// which `LiveCoordinator` swaps in and out as the Mac link changes.
    public static let shared = ChiefSession(backend: defaultBackend())

    /// The Cloud Chief: the main conversation of the user's Cloud Chief
    /// (``ChiefCloudBackend``), set by ``ChiefSources`` after sign-in. Home
    /// shows it first when it answers; offline until then.
    public static let cloud = ChiefSession(
        backend: ChiefOfflineBackend(reason: ChiefSources.signedOutReason),
        outbox: .cloud
    )

    /// Chief before a Mac link: offline (``ChiefOfflineBackend``). DEBUG
    /// builds use the package's conversation simulator
    /// (`services/conversation-sim`) when `CMUX_MOBILE_CHIEF_SIM` names its WebSocket
    /// (`ws://127.0.0.1:4870/ws?conversation=direct`), so Chief can be
    /// compared with the package's own lab host on the same data
    /// (verify/imsg-parity.md), and the scripted mock only with mock content on.
    static func defaultBackend() -> any ConversationBackend {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CMUX_MOBILE_CHIEF_SIM"], let url = URL(string: raw) {
            return ConversationSimBackend(endpoint: url)
        }
        #endif
        return fallbackBackend(mockContentEnabled: DeveloperOptions.mockContentEnabled)
    }

    /// The backend with no Mac link: the mock only with mock content on (DEBUG).
    public static func fallbackBackend(mockContentEnabled: Bool) -> any ConversationBackend {
        #if DEBUG
        if mockContentEnabled { return ChiefMockBackend() }
        #endif
        return ChiefOfflineBackend()
    }

    public private(set) var store: ConversationStore
    public private(set) var lastMessage: ConversationMessage?
    public private(set) var unreadCount = 0
    public private(set) var isTyping = false
    public private(set) var isConnected = false
    /// Why Chief is not reachable (no Mac, Chief not started there), set by
    /// whoever swaps the backend; nil when there is nothing to explain.
    /// Setting it ends a Try Again in flight (the try came back).
    public var status: String? {
        didSet { isReconnecting = false }
    }
    /// Tries the Mac's Chief again (set by the link's coordinator); nil
    /// where there is nothing to try (no link).
    @ObservationIgnored public var reconnect: (@MainActor () -> Void)?
    /// A Try Again is in flight: the bar shows progress until ``status`` is
    /// set again or Chief connects.
    public private(set) var isReconnecting = false
    /// The backend the store runs on.
    public private(set) var backend: any ConversationBackend
    /// Who is in the conversation; the Cloud Chief's ids come with its backend.
    public private(set) var identity: ChiefIdentity
    /// The brain's engine controls, when the backend is the Mac's Chief.
    public private(set) var control: ChiefControl?
    /// The Mac Chief runs on, for the settings page.
    public var macName: String?
    /// Reads a file a Chief message links to from Chief's Mac (the link's `file`
    /// service, inside the folders that Mac shares); nil without a Mac link.
    @ObservationIgnored public var fileSource: (any ArtifactSource)?
    public let preferences: ChiefPreferences
    /// Chief's avatar text (``ChiefIdentity/avatar``): the Mac's, once its
    /// `chief.engine.get` reply carries one, else "C".
    public private(set) var avatar: String
    /// The Mac Chief's newest engine report (``ChiefControl/engine()``),
    /// else the last one this phone read from that Mac (kept per Mac in
    /// ``ChiefPreferences``), so the settings page always shows a model.
    public private(set) var engineReport: ChiefEngineReport?
    /// Whether ``engineReport`` came from this connection (false: the copy
    /// kept from an earlier one, shown while the Mac's Chief can't answer).
    public private(set) var engineReportIsCurrent = false
    /// Why the newest engine read failed (or came back without models); nil
    /// once a read listed them.
    public private(set) var engineProblem: ChiefEngineProblem?
    /// The Mac Chief runs on (its link device id): the key of the kept engine report.
    public var macID: String? {
        didSet {
            guard macID != oldValue else { return }
            // Only while no Chief is attached: the coordinator names the next
            // Mac before that Mac's backend replaces the current one, and until
            // then what is written (and what flushes) is still the current Chief's.
            if backend is ChiefOfflineBackend {
                outboxTarget = Self.target(of: backend, macID: macID, previous: outboxTarget)
                refreshOutbox()
            }
            guard !engineReportIsCurrent else { return }
            engineReport = macID.flatMap { preferences.engineReport(macID: $0) }
        }
    }
    /// Waits between engine reads after a failure (``watchEngine()``).
    let clock: any Clock<Duration>
    /// Chief's questions in the conversation, in message order.
    public private(set) var questions: [AgentQuestion] = []
    /// Each answer's progress, by question id (``ChiefAnswerFlow``).
    public private(set) var answers: [String: ChiefAnswerFlow] = [:]
    /// The signer for answers (Face ID with this phone's approval key), asked
    /// at answer time: the link's pairing may change while Chief is open.
    public var answerSigner: (@MainActor () -> (any ChiefAnswerSigning)?)?
    /// The newest message the user has seen with the conversation open.
    private var seenMessageID: String?
    /// Messages waiting for this Chief to connect (``ChiefOutbox``): the ones
    /// written to the Chief open now (``outboxTarget``), or to no Chief in
    /// particular. Messages for another Mac or Cloud Chief wait in ``parked``
    /// and go out only when that Chief is the one open again.
    public private(set) var outbox: [ConversationComposeMessage] = []
    /// Each waiting message with the Chief it was written to.
    private var waiting: [ChiefOutbox.Waiting] = []
    private let outboxStore: ChiefOutbox
    /// The Chief a message sent now is for: `mac:<id>` for a Mac's Chief (its
    /// link, or its cloud copy while the Mac is away), `cloud:<conversation>`
    /// for a Cloud Chief. Nil before either is known.
    public private(set) var outboxTarget: String?
    /// Newest message seq already seen; newer ones from Chief alert.
    private var alertedSeq: Int?

    public init(backend: any ConversationBackend, identity: ChiefIdentity = .standard,
                preferences: ChiefPreferences = ChiefPreferences(), outbox: ChiefOutbox? = nil,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.identity = identity
        self.clock = clock
        avatar = identity.avatar
        self.preferences = preferences
        outboxStore = outbox ?? .standard
        waiting = outboxStore.load()
        self.backend = backend
        outboxTarget = Self.target(of: backend, macID: nil, previous: nil)
        store = ConversationStore(backend: backend)
        control = (backend as? ChiefDaemonBackend)?.control
        refreshOutbox()
        ChiefAlerts.shared.install()
        attach()
        #if canImport(UIKit)
        // Back in the foreground: Chief may have recovered while the app
        // was away (its model server came back); read it again.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadEngine() }
        }
        #endif
    }

    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?

    /// Swaps the backend (offline to `ChiefDaemonBackend` once a Mac link is
    /// up, or to ``ChiefCloudBackend`` with the Cloud Chief's `identity`).
    public func use(_ backend: any ConversationBackend, identity: ChiefIdentity? = nil) {
        // Sends the old backend never confirmed (still sending, or Not
        // Delivered) live only in its store: keep them in the outbox for the
        // Chief they were written to, or they vanish with the store.
        let unconfirmed = store.messages.filter { message in
            message.senderID == store.meID && message.seq == nil && !message.isScheduled
                && (message.delivery == .sending || message.delivery?.isFailed == true)
        }
        let carried = unconfirmed.compactMap { message -> ChiefOutbox.Waiting? in
            let kept = ConversationComposeMessage(text: message.text, images: message.attachments.compactMap { attachment in
                guard attachment.kind == .image, let data = attachment.localData else { return nil }
                return ConversationComposeImage(data: data, width: attachment.width, height: attachment.height, mimeType: "image/jpeg")
            })
            // The client id lets the flush skip one the Chief got after all.
            return kept.isEmpty ? nil : ChiefOutbox.Waiting(message: kept, target: outboxTarget, clientID: message.clientMessageID)
        }
        if !carried.isEmpty {
            waiting += carried
            outboxStore.save(waiting)
        }
        store.stop()
        if let identity, identity != self.identity {
            self.identity = identity
            avatar = identity.avatar
        }
        live = nil
        answeredLiveStep = nil
        self.backend = backend
        store = ConversationStore(backend: backend)
        control = (backend as? ChiefDaemonBackend)?.control
        // The kept report stays on screen until this connection reads one.
        engineReport = macID.flatMap { preferences.engineReport(macID: $0) }
        engineReportIsCurrent = false
        engineProblem = nil
        lastTurnFailure = nil
        lastTurnFailureID = nil
        alertedSeq = nil
        questions = []
        answers = [:]
        outboxTarget = Self.target(of: backend, macID: macID, previous: outboxTarget)
        refreshOutbox()
        attach()
    }

    /// The Chief `backend` talks to (``outboxTarget``). An offline backend
    /// keeps the Chief that was open: what is written meanwhile is for it.
    static func target(of backend: any ConversationBackend, macID: String?, previous: String?) -> String? {
        if let cloud = backend as? ChiefCloudBackend { return "cloud:\(cloud.conversationID)" }
        if let macID { return "mac:\(macID)" }
        return backend is ChiefOfflineBackend ? previous : nil
    }

    /// ``outbox``: what waits for the Chief open now.
    private func refreshOutbox() {
        let shown = waiting.filter { $0.target == nil || $0.target == outboxTarget }.map(\.message)
        if shown != outbox { outbox = shown }
    }

    /// Chief's newest message, when it reports a failed turn (the
    /// conversation shows it in plain words; this keeps the raw detail).
    public private(set) var lastTurnFailure: ChiefTurnFailure?
    /// The id of that message.
    public private(set) var lastTurnFailureID: String?
    /// The failed message whose Try Again was sent (its bar goes away).
    private var retriedFailureID: String?

    /// What the bar over the conversation shows: the open question first,
    /// else Try Again for a failed newest turn not tried again yet.
    public var barItem: ChiefBarItem? {
        if let question = openQuestion { return .question(question) }
        // The Mac's Chief refused or is missing (D2): say why, instead of
        // the conversation's endless first-load spinner.
        if !isConnected, let status { return .unavailable(reason: status, retrying: isReconnecting) }
        if let id = lastTurnFailureID, let failure = lastTurnFailure, id != retriedFailureID, isConnected {
            return .failure(id: id, failure)
        }
        // The Mac is away (its cloud copy): say so, with the Cloud Chief hand-off.
        if isConnected, backend is ChiefReplicaBackend, let status { return .macAway(reason: status) }
        return nil
    }

    /// Try Again on the unavailable bar has something to try.
    public var canRetryConnecting: Bool { reconnect != nil }

    /// Try Again on the unavailable bar: asks the coordinator to open the
    /// Mac's Chief again. A second tap while one runs does nothing.
    public func retryConnecting() {
        guard let reconnect, !isReconnecting else { return }
        isReconnecting = true
        reconnect()
    }

    /// Composer text of a Chief screen that went away, for the screen that replaces it.
    private var carriedComposerText: String?

    /// The leaving screen's unsent text (empty clears it).
    public func carryComposerText(_ text: String) {
        carriedComposerText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The carried text, once.
    public func takeCarriedComposerText() -> String? {
        defer { carriedComposerText = nil }
        return carriedComposerText
    }

    /// The coordinator's try ended (connected, refused or replaced): Try Again is offered again.
    public func endReconnect() {
        if isReconnecting { isReconnecting = false }
    }

    /// The conversation's own send takes a message now. Before Chief ever
    /// connected it has no sender and drops the message after clearing the
    /// composer (D3), so the screen holds the text and sends it through
    /// ``send(_:)`` (the outbox) instead.
    public var acceptsSendsNow: Bool { store.meID != nil }

    /// What Chief is doing right now (Live frames v1), when its backend
    /// carries live frames (``ChiefLiveSource``); nil when nothing runs.
    public private(set) var live: ChiefLive?
    /// The live talk step whose reply message already arrived: its bubble
    /// goes away with the message, before the run's end frame.
    private var answeredLiveStep: String?

    /// The live run the transcript draws (the streaming reply bubble and the
    /// status line): ``live``, without the reply text once its message arrived.
    public var shownLive: ChiefLive? {
        guard let live else { return nil }
        if let step = live.step, answeredLiveStep == "\(live.key)\u{0}\(step)" {
            // The reply is in the transcript; the run's status line stays
            // until the run ends.
            var rest = live
            rest.step = nil
            rest.text = ""
            return rest
        }
        return live
    }

    /// Chief is typing or a run is live: Home's pin shows the typing bubble.
    public var isWorking: Bool { isTyping || live != nil }

    /// This Chief runs in cmux Cloud (not on a Mac).
    public var runsInCloud: Bool { backend is ChiefCloudBackend }

    /// Try Again on a failed turn: the brain does not run a failed turn
    /// again by itself (it retries only connection errors and capacity
    /// waits, before it posts), so this sends the user's message that the
    /// turn answered again, as a new message: Chief answers it once its
    /// model is back. Does nothing without a failed newest turn.
    public func retryFailedTurn() {
        guard isConnected, let id = lastTurnFailureID, id != retriedFailureID,
              let failed = store.messages.first(where: { $0.id == id }),
              let asked = store.messages.last(where: { message in
                  message.senderID == store.meID && !message.isUnsent && !message.isScheduled
                      && message.seq != nil && (message.seq ?? 0) < (failed.seq ?? .max)
              }), let retry = ChiefRetryMessage(asked) else { return }
        // Set this before send: the store notifies observers synchronously.
        retriedFailureID = id
        if !retry.send(to: store) { retriedFailureID = nil }
    }

    /// The question waiting for an answer from this phone: the newest
    /// pending one, or one whose answer is in flight or failed.
    public var openQuestion: AgentQuestion? {
        questions.last { question in
            question.isPending || (answers[question.id].map { $0.isBusy || $0.state == .unconfirmed } ?? false)
        }
    }

    /// Answers `question` (Face ID, then the Mac). The flow says where it is;
    /// a second call while one is in flight does nothing.
    public func answer(_ question: AgentQuestion, with answer: AgentQuestionAnswer) {
        guard let source = backend as? any ChiefQuestionSource else { return }
        var flow = answers[question.id] ?? ChiefAnswerFlow()
        guard flow.begin() else { return }
        answers[question.id] = flow
        let id = question.id
        let signer = answerSigner?()
        let approved: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.answers[id]?.approved() }
        }
        Task { @MainActor [weak self] in
            do {
                try await source.answer(question, with: answer, signer: signer, approved: approved)
                // The approval hop can still be queued: approve before storing.
                self?.answers[id]?.approved()
                self?.answers[id]?.stored()
            } catch {
                self?.answers[id]?.failed(error)
            }
        }
    }

    /// Check after a lost reply (R2-5): fetches the conversation again; the
    /// question's state on the Mac settles the answer's.
    public func checkAnswer(_ questionID: String) {
        guard let source = backend as? any ChiefQuestionSource, var flow = answers[questionID], flow.beginCheck() else { return }
        answers[questionID] = flow
        Task { @MainActor [weak self] in
            do {
                try await source.recheckQuestions()
                guard let self else { return }
                let current = source.questionFeed.current.first { $0.id == questionID }
                if let current, !current.isPending {
                    self.answers[questionID]?.stored()
                } else {
                    self.answers[questionID]?.checkedStillPending()
                }
            } catch {
                self?.answers[questionID]?.failed(error)
            }
        }
    }

    /// Keeps what the Mac Chief's engine report says about Chief (its
    /// avatar) for every place Chief is drawn; the details page calls it
    /// with each report it reads or writes.
    public func adopt(_ report: ChiefEngineReport) {
        // A report without models (the Mac's Chief could not list them)
        // keeps the models of the kept one, so the picker still offers them.
        var report = report
        if let problem = ChiefEngineProblem(report: report) {
            if let kept = engineReport {
                report.offered.models = kept.offered.models
                if report.offered.defaultModel == nil { report.offered.defaultModel = kept.offered.defaultModel }
            }
            engineProblem = problem
        } else {
            engineProblem = nil
            if let macID { preferences.setEngineReport(report, macID: macID) }
        }
        engineReport = report
        engineReportIsCurrent = true
        if let daemon = backend as? ChiefDaemonBackend {
            // The backend draws the header; `refresh` reads it back from the store.
            Task { await daemon.applyAvatar(report.avatar) }
        } else {
            let text = report.avatar ?? identity.avatar
            if avatar != text { avatar = text }
        }
    }

    /// Reads the engine report once Chief is reachable over the Mac link.
    private func loadEngine() {
        Task { @MainActor [weak self] in await self?.refreshEngine() }
    }

    /// Reads the Mac Chief's engine report now. On failure the report
    /// shown stays (this connection's, or the one kept for this Mac) and
    /// ``engineProblem`` says why; returns that problem (nil: models listed).
    @discardableResult
    public func refreshEngine() async -> ChiefEngineProblem? {
        guard let control else { return nil }
        let store = store
        do {
            let report = try await control.engine()
            guard self.store === store else { return nil }
            engineError = nil
            adopt(report)
        } catch {
            guard self.store === store else { return nil }
            engineProblem = ChiefEngineProblem(error)
            engineError = error
        }
        return engineProblem
    }

    /// The raw error of the newest failed engine read (diagnostics only).
    public private(set) var engineError: (any Error)?

    /// The waits between engine reads while one keeps failing: 2, 4, 8,
    /// 16, then every 30 s.
    nonisolated static func retryDelay(attempt: Int) -> Duration {
        attempt >= 4 ? .seconds(30) : .seconds(2 << max(0, attempt))
    }

    /// Keeps Chief's engine report fresh while someone looks at it (the
    /// settings page runs this as its task): reads it now, and while the
    /// read fails for a reason that can pass (the Mac or its model server
    /// is down), again with backoff until it lists models. Ends when the
    /// task is cancelled or the problem needs a person (Chief not set up).
    public func watchEngine() async {
        var attempt = 0
        while !Task.isCancelled, control != nil {
            guard let problem = await refreshEngine(), problem.isTransient else { return }
            do { try await clock.sleep(for: Self.retryDelay(attempt: attempt)) } catch { return }
            attempt += 1
        }
    }

    /// This Chief's conversation is on screen (set by its screen): its new
    /// messages are seen and raise no alert. Per Chief: an open Mac Chief
    /// never marks the Cloud Chief's messages seen, nor the reverse.
    @ObservationIgnored public var isVisible = false

    /// The conversation is on screen: what it shows now has been seen.
    public func markSeen() {
        seenMessageID = lastMessage?.id
        guard let id = conversationID else { return }
        // Kept for the next launch (in memory only, every question seen
        // before a relaunch came back as Needs You).
        if let seen = seenMessageID, preferences.seenMessageID(id) != seen { preferences.setSeenMessageID(seen, id) }
        // Its alerts in Notification Center are read now too.
        ChiefAlerts.shared.clearDelivered(conversationID: id)
    }

    /// Chief is waiting on the user: a message is still in the outbox, or
    /// Chief's newest message asks a question the user has not opened the
    /// chat to see. Home's pin keeps its preview bubble up for it.
    public var isWaitingOnYou: Bool {
        if !outbox.isEmpty { return true }
        guard let message = lastMessage, message.senderID == identity.chiefID, !message.isUnsent else { return false }
        return message.text.contains("?") && message.id != seenMessageID
            && conversationID.map { preferences.seenMessageID($0) != message.id } ?? true
    }

    /// Home's Needs You filter: something waits in the outbox, Chief is
    /// waiting on the user (the pin's preview, F6), or Chief is idle with its
    /// newest message unread.
    public var needsYou: Bool {
        if !outbox.isEmpty || isWaitingOnYou { return true }
        guard !isTyping, let message = lastMessage else { return false }
        return message.senderID == identity.chiefID && unreadCount > 0
    }

    /// The conversation the store shows, once connected.
    public var conversationID: String? { store.info?.id }

    /// The conversation's name on the Mac (`title.set` from any device).
    public private(set) var title: String?
    /// Hide Alerts, as the details page and Home's pin show it.
    public private(set) var isMuted = false
    public private(set) var sendsReadReceipts = true

    /// Hide Alerts; `rejected` runs if the change could not be saved.
    public func setMuted(_ muted: Bool, rejected: (@MainActor () -> Void)? = nil) {
        store.updateListState(ConversationListStateChange(muted: muted)) { _ in rejected?() }
        if muted, let id = conversationID { ChiefAlerts.shared.clearDelivered(conversationID: id) }
    }

    public func setSendsReadReceipts(_ on: Bool, rejected: (@MainActor () -> Void)? = nil) {
        store.updateListState(ConversationListStateChange(sendReadReceipts: on)) { _ in rejected?() }
    }

    /// Renames the conversation on the Mac (`title.set`).
    public func rename(_ title: String) async throws {
        guard let backend = backend as? ChiefDaemonBackend else {
            throw ConversationBackendError(code: -1, message: String(localized: "Chief isn't connected to a Mac"))
        }
        try await backend.rename(title)
    }

    private func attach() {
        let store = store
        if let source = backend as? any ChiefLiveSource {
            source.liveFeed.observe { [weak self] live in
                Task { @MainActor [weak self] in
                    guard let self, self.store === store, self.live != live else { return }
                    self.live = live
                }
            }
        }
        if let source = backend as? any ChiefQuestionSource {
            source.questionFeed.observe { [weak self] found in
                Task { @MainActor [weak self] in
                    guard let self, self.store === store, self.questions != found else { return }
                    self.questions = found
                    // A lost reply whose answer the Mac did store reads Sent.
                    for question in found where !question.isPending && self.answers[question.id]?.state == .unconfirmed {
                        self.answers[question.id]?.stored()
                    }
                }
            }
        }
        store.addObserver { [weak self, weak store] _ in
            guard let self, let store, store === self.store else { return }
            self.refresh()
        }
        store.start()
        refresh()
        loadEngine()
    }

    private func refresh() {
        let newest = store.messages.last { $0.seq != nil && !$0.isScheduled }
        if newest != lastMessage {
            // A new reply from Chief replaces the streaming bubble of the live talk step.
            if let newest, newest.id != lastMessage?.id, newest.senderID == identity.chiefID,
               let live, let step = live.step {
                answeredLiveStep = "\(live.key)\u{0}\(step)"
            }
            lastMessage = newest
        }
        // A failed turn is offered for Try Again only while it is the newest message.
        let failure = newest.flatMap { message in
            message.senderID == identity.chiefID
                ? (backend as? ChiefDaemonBackend)?.failureLog.failure(messageID: message.id) : nil
        }
        if failure != lastTurnFailure || (failure == nil ? nil : newest?.id) != lastTurnFailureID {
            lastTurnFailure = failure
            lastTurnFailureID = failure == nil ? nil : newest?.id
        }
        if isVisible, seenMessageID != newest?.id {
            seenMessageID = newest?.id
            if let seen = seenMessageID, let id = conversationID, preferences.seenMessageID(id) != seen {
                preferences.setSeenMessageID(seen, id)
            }
        }
        if unreadCount != store.unreadCount {
            // Read on another device (the Mac): its alerts here are read too.
            if store.unreadCount == 0, let id = conversationID { ChiefAlerts.shared.clearDelivered(conversationID: id) }
            unreadCount = store.unreadCount
        }
        let typing = store.typingParticipantIDs.contains(identity.chiefID)
        if isTyping != typing { isTyping = typing }
        let connected = store.connection == .connected
        if isConnected != connected { isConnected = connected }
        if connected, isReconnecting { isReconnecting = false }
        if title != store.info?.title { title = store.info?.title }
        // Chief's avatar as the conversation draws it (the Mac's text, live).
        if let drawn = store.info?.participants.first(where: { $0.id == identity.chiefID })?.initials,
           !drawn.isEmpty, drawn != avatar {
            avatar = drawn
        }
        let listState = store.info?.listState
        if isMuted != (listState?.muted ?? false) { isMuted = listState?.muted ?? false }
        if sendsReadReceipts != (listState?.sendReadReceipts ?? true) { sendsReadReceipts = listState?.sendReadReceipts ?? true }
        alertNewMessages()
        flushOutbox()
    }

    /// Sends a message to Chief: now when Chief has connected, else into the
    /// outbox, which goes out when it connects (never dropped silently).
    /// `asksForAlerts`: the composer's first send asks for notification
    /// permission (Chief's replies alert); a live call's send doesn't, so no
    /// system prompt lands over the call screen.
    /// A text message (Send Message… on a workspace or a tab, with its link at the start).
    public func send(text: String) {
        send(ConversationComposeMessage(text: text))
    }

    public func send(_ message: ConversationComposeMessage, asksForAlerts: Bool = true) {
        guard !message.isEmpty else { return }
        if asksForAlerts { ChiefAlerts.shared.requestPermissionIfUndetermined() }
        if store.meID != nil, store.connection == .connected {
            store.sendWhenConnected(message)
            return
        }
        waiting.append(ChiefOutbox.Waiting(message: message, target: outboxTarget))
        outboxStore.save(waiting)
        refreshOutbox()
    }

    /// Drops what waits in the outbox for this Chief (the user chose not to send it).
    public func discardOutbox() {
        waiting.removeAll { $0.target == nil || $0.target == outboxTarget }
        outboxStore.save(waiting)
        refreshOutbox()
    }

    private func flushOutbox() {
        guard !outbox.isEmpty, store.meID != nil, store.connection == .connected else { return }
        let mine = waiting.filter { $0.target == nil || $0.target == outboxTarget }
        // A send carried over a dropped link may have reached the Chief before
        // the drop: wait for the newest page, and skip any it already has.
        if mine.contains(where: { $0.clientID != nil }), !store.hasLoadedNewest { return }
        let delivered = Set(store.messages.compactMap(\.clientMessageID))
        let ready = mine.filter { $0.clientID.map { !delivered.contains($0) } ?? true }.map(\.message)
        waiting.removeAll { $0.target == nil || $0.target == outboxTarget }
        outboxStore.save(waiting)
        refreshOutbox()
        guard !ready.isEmpty else { return }
        // Not from inside the store's own change callback.
        let store = store
        Task { @MainActor in
            for message in ready { store.sendWhenConnected(message) }
        }
    }

    /// Alerts for Chief's messages that arrived live (not the first page).
    private func alertNewMessages() {
        guard store.connection == .connected, let id = conversationID else { return }
        // Messages are in seq order: the newest numbered one is near the end
        // (this runs on every store change, each keystroke and stream chunk).
        let newest = store.messages.last { $0.seq != nil }?.seq ?? 0
        guard let seen = alertedSeq else {
            // The store says connected before its first page lands: what
            // that page brings is history, not news.
            if newest > 0 { alertedSeq = newest }
            return
        }
        guard newest > seen else { return }
        alertedSeq = newest
        for message in store.messages where (message.seq ?? 0) > seen && message.senderID == identity.chiefID {
            ChiefAlerts.shared.notify(message, title: store.info?.title ?? identity.title, conversationID: id, macID: macID,
                                     preferences: preferences, visible: isVisible)
        }
    }

    /// Why Chief cannot answer now, for the list and the settings page.
    public var unavailableReason: String? {
        if isConnected { return nil }
        return status ?? (backend as? ChiefOfflineBackend)?.reason
    }

    /// The list's preview line for the newest message.
    public var preview: String {
        if let waiting = outbox.last {
            return String(localized: "Waiting to send: \(waiting.text.isEmpty ? String(localized: "Attachment") : waiting.text)")
        }
        guard let message = lastMessage else { return unavailableReason ?? String(localized: "Ask Chief to run agents on your Macs.") }
        if message.isUnsent { return String(localized: "Message unsent") }
        if message.text.isEmpty, !message.attachments.isEmpty { return String(localized: "Attachment") }
        return message.text
    }
}

// MARK: - Outbox

/// Messages written to Chief before it connected (New Message to Chief
/// while the link is still coming up, or the Mac has no Chief yet). They
/// are kept on disk, survive a backend swap and a relaunch, and go out in
/// order once Chief connects; after that the transcript shows each one's
/// delivery (and Not Delivered, with retry) as for any message.
public struct ChiefOutbox: Sendable {
    /// A waiting message and the Chief it is for (``ChiefSession/outboxTarget``).
    struct Waiting: Equatable {
        var message: ConversationComposeMessage
        var target: String?
        /// The client id of a send carried over a backend swap (nil for one
        /// written while Chief was away).
        var clientID: String?
    }

    struct Item: Codable, Equatable {
        var text: String
        var images: [Image]
        /// Nil in files written before messages named their Chief.
        var target: String?
        var clientID: String?

        struct Image: Codable, Equatable {
            var data: Data
            var width: Int
            var height: Int
            var mimeType: String
        }
    }

    let file: URL?

    public init(file: URL?) {
        self.file = file
    }

    public static var standard: ChiefOutbox {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return ChiefOutbox(file: directory?.appendingPathComponent("cmux-mobile-chief-outbox.json"))
    }

    /// The Cloud Chief's outbox, apart from the Mac Chief's.
    public static var cloud: ChiefOutbox {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return ChiefOutbox(file: directory?.appendingPathComponent("cmux-mobile-cloud-chief-outbox.json"))
    }

    func load() -> [Waiting] {
        guard let file, let data = try? Data(contentsOf: file),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { item in
            Waiting(message: ConversationComposeMessage(text: item.text, images: item.images.map {
                ConversationComposeImage(data: $0.data, width: $0.width, height: $0.height, mimeType: $0.mimeType)
            }), target: item.target, clientID: item.clientID)
        }
    }

    func save(_ messages: [Waiting]) {
        guard let file else { return }
        guard !messages.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let items = messages.map { waiting in
            Item(text: waiting.message.text, images: waiting.message.images.map {
                Item.Image(data: $0.data, width: $0.width, height: $0.height, mimeType: $0.mimeType)
            }, target: waiting.target, clientID: waiting.clientID)
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable after first unlock, so a message written on a locked phone is kept.
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
