#if os(iOS)
public import CmuxChiefVoiceCore
import AVFoundation
import CmuxConversationCore
public import CmuxMobileChief
import Foundation
import Observation

/// Shows the Chief call screen and runs the call behind it.
///
/// The Action Button, Siri and Shortcuts intents call ``handle(_:)``: the
/// screen comes up and recording starts at once; a second press while
/// recording ends the call. The finished note is transcribed on the phone and
/// sent to the default Chief (``ChiefSources/primary``) as text; the Chief
/// session keeps it in its own outbox while the Chief is not connected.
@MainActor
@Observable
public final class ChiefVoiceController {
    /// The request the call screen shows; nil while the screen is closed.
    public private(set) var presented: ChiefVoiceRequest?
    /// The call state the screen renders; signed-out controllers are idle.
    public var state: ChiefCallState { coordinator?.state ?? .idle }
    /// The Chief's name for the screen title.
    public var chiefName: String? { sources.primary.title }

    @ObservationIgnored private let sources: ChiefSources
    @ObservationIgnored private let recorder: any VoiceRecording
    @ObservationIgnored private let transcriber: any VoiceTranscribing
    @ObservationIgnored private let microphone: any MicrophoneAuthorizing
    @ObservationIgnored private let notesRoot: URL
    @ObservationIgnored private let noTranscript: @Sendable (TimeInterval) -> String
    @ObservationIgnored private var coordinator: ChiefCallCoordinator?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var pending: PendingRequest?
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var interruptions: Task<Void, Never>? = nil

    /// Creates an account-scoped controller from injected voice services.
    /// - Parameters:
    ///   - sources: Which authenticated account and Chief are active.
    ///   - recorder: Records audio into the current account's outbox.
    ///   - transcriber: Produces the on-device transcript.
    ///   - microphone: Requests recording permission.
    ///   - notesRoot: Parent directory for account-scoped outboxes.
    ///   - noTranscript: Builds the fallback message for an untranscribed note.
    ///   - interruptions: Yields when another audio user takes the session; each ends the call.
    public init(sources: ChiefSources, recorder: any VoiceRecording, transcriber: any VoiceTranscribing,
                microphone: any MicrophoneAuthorizing, notesRoot: URL,
                noTranscript: @escaping @Sendable (TimeInterval) -> String,
                interruptions: AsyncStream<Void>) {
        self.sources = sources
        self.recorder = recorder
        self.transcriber = transcriber
        self.microphone = microphone
        self.notesRoot = notesRoot
        self.noTranscript = noTranscript
        self.interruptions = Task { [weak self] in
            for await _ in interruptions { await self?.end() }
        }
    }

    /// The app's controller: the phone's microphone, on-device speech, an
    /// outbox in Application Support, and delivery to the default Chief.
    /// - Parameter sources: The Chiefs Home shows.
    public static func live(sources: ChiefSources) -> ChiefVoiceController {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("ChiefVoiceNotes", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChiefVoiceNotes", isDirectory: true)
        let recorder = AudioSessionRecorder(session: .sharedInstance())
        return ChiefVoiceController(
            sources: sources, recorder: recorder, transcriber: OnDeviceSpeechTranscriber(locale: .current),
            microphone: MicrophonePermission(), notesRoot: directory,
            noTranscript: { seconds in VoiceText.noTranscript(seconds: Int(seconds.rounded())) },
            interruptions: recorder.interruptions()
        )
    }

    /// Selects the authenticated account and its private pending-note outbox.
    ///
    /// A recording owned by the previous account is stopped and retained in
    /// that account's outbox; its delivery guard refuses the new account.
    /// - Parameter userID: The active account, or `nil` after sign-out.
    public func selectAccount(_ userID: String?) async {
        await enqueue { controller in await controller.selectAccountNow(userID) }
    }

    private func selectAccountNow(_ userID: String?) async {
        if userID == accountID {
            await resumePending(for: userID)
            return
        }
        let previous = coordinator
        if let pending, pending.accountID != nil, pending.accountID != userID { self.pending = nil }
        accountID = userID
        coordinator = nil
        presented = nil
        await previous?.end()
        guard let userID else { return }
        coordinator = makeCoordinator(accountID: userID)
        await resumePending(for: userID)
    }

    /// Opens the call screen for `request` and starts, or ends, the call.
    /// - Parameter request: A call or a voice note.
    public func handle(_ request: ChiefVoiceRequest) async {
        await enqueue { controller in await controller.handleNow(request) }
    }

    private func handleNow(_ request: ChiefVoiceRequest) async {
        guard let userID = sources.activeUserID else {
            pending = PendingRequest(request: request, accountID: accountID)
            return
        }
        await selectAccountNow(userID)
        guard let coordinator else {
            pending = PendingRequest(request: request, accountID: userID)
            return
        }
        if presented == nil { presented = request }
        await coordinator.handle(request)
    }

    /// Closes the screen; a running recording ends and is sent first.
    public func dismiss() {
        presented = nil
        guard let coordinator, case .recording = coordinator.state else { return }
        Task { [weak self] in await self?.end() }
    }

    /// Ends the current account's recording, if one is running.
    public func end() async {
        await enqueue { controller in await controller.coordinator?.end() }
    }

    /// Sends notes an earlier call left in the outbox.
    public func drainOutbox() async {
        await enqueue { controller in
            guard let userID = controller.sources.activeUserID else { return }
            await controller.selectAccountNow(userID)
            await controller.coordinator?.drainOutbox()
        }
    }

    private func makeCoordinator(accountID: String) -> ChiefCallCoordinator {
        let delivery = ChiefVoiceTextDelivery(
            send: { [weak self, weak sources] text in
                guard let self, let sources, self.accountID == accountID, sources.activeUserID == accountID else {
                    throw AccountChanged()
                }
                try await sources.primary.send(ConversationComposeMessage(text: text))
            },
            noTranscript: noTranscript
        )
        return ChiefCallCoordinator(
            recorder: recorder, transcriber: transcriber, microphone: microphone, delivery: delivery,
            outbox: VoiceNoteOutbox(rootDirectory: notesRoot, accountID: accountID)
        )
    }

    private func resumePending(for accountID: String?) async {
        guard let accountID, let pending,
              pending.accountID == nil || pending.accountID == accountID else { return }
        self.pending = nil
        await handleNow(pending.request)
    }

    private func enqueue(_ operation: @escaping @MainActor @Sendable (ChiefVoiceController) async -> Void) async {
        operationGeneration += 1
        let generation = operationGeneration
        let preceding = operationTail
        let task = Task { @MainActor [weak self] in
            await preceding?.value
            guard let self else { return }
            await operation(self)
        }
        operationTail = task
        await task.value
        if generation == operationGeneration { operationTail = nil }
    }

    private struct PendingRequest {
        var request: ChiefVoiceRequest
        var accountID: String?
    }
    private struct AccountChanged: Error {}
}
#endif
