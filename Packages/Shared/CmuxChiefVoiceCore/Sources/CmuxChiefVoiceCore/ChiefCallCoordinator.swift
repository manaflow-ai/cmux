import Foundation
import Observation

/// Runs one Chief call or voice note from request to delivery.
///
/// The flow (plans/cmux-next/ios-action-button-DESIGN.md section 4): a request
/// asks for the microphone, records into the ``VoiceNoteOutbox`` at once, and on
/// ``end()`` (or ``interrupted()``, or a second request while recording) stops,
/// saves the note, transcribes it on device and delivers audio plus transcript
/// to the Chief. A failed delivery keeps the note in the outbox
/// (``ChiefCallState/savedForLater(_:)``); ``drainOutbox()`` retries it. A
/// failed transcription still delivers the audio.
///
/// Every dependency is injected, so tests drive the whole flow with fakes:
///
/// ```swift
/// let call = ChiefCallCoordinator(recorder: FakeRecorder(), transcriber: FakeTranscriber(),
///                                 microphone: FakeMicrophone(), delivery: FakeDelivery(),
///                                 outbox: VoiceNoteOutbox(directory: tempDirectory))
/// await call.handle(.call)   // recording
/// await call.end()           // sent, or savedForLater
/// ```
@MainActor
@Observable
public final class ChiefCallCoordinator {
    /// The current step of the flow.
    public private(set) var state: ChiefCallState = .idle

    /// The note being recorded or finished, if any.
    @ObservationIgnored private var current: VoiceNote?
    @ObservationIgnored private var draining = false

    @ObservationIgnored private let recorder: any VoiceRecording
    @ObservationIgnored private let transcriber: any VoiceTranscribing
    @ObservationIgnored private let microphone: any MicrophoneAuthorizing
    @ObservationIgnored private let delivery: any ChiefVoiceDelivering
    @ObservationIgnored private let outbox: VoiceNoteOutbox
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Creates a coordinator.
    /// - Parameters:
    ///   - recorder: Records the microphone into the outbox audio file.
    ///   - transcriber: On-device transcription of a finished note.
    ///   - microphone: Microphone permission.
    ///   - delivery: Sends a finished note to the Chief conversation.
    ///   - outbox: Holds notes until delivered.
    ///   - now: The clock for ``VoiceNote/createdAt`` (default: the system clock; tests pin it).
    public init(recorder: any VoiceRecording, transcriber: any VoiceTranscribing,
                microphone: any MicrophoneAuthorizing, delivery: any ChiefVoiceDelivering,
                outbox: VoiceNoteOutbox, now: @escaping @Sendable () -> Date = { Date() }) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.microphone = microphone
        self.delivery = delivery
        self.outbox = outbox
        self.now = now
    }

    /// Handles a request from an entry point.
    ///
    /// Idle (or after a finished call): asks for the microphone and starts
    /// recording; returns once recording runs. While recording: ends the call,
    /// so pressing the Action Button again hangs up. While asking for
    /// permission or finishing: ignored.
    /// - Parameter request: The entry point's request.
    public func handle(_ request: ChiefVoiceRequest) async {
        switch state {
        case .recording:
            await end()
            return
        case .requestingPermission, .finishing, .transcribing, .sending:
            return
        case .idle, .permissionDenied, .sent, .savedForLater, .failed:
            break
        }
        state = .requestingPermission
        guard await microphone.requestAccess() else {
            state = .permissionDenied
            return
        }
        let note = VoiceNote(mode: request, createdAt: now())
        do {
            try await outbox.prepareDirectory()
            try await recorder.start(writingTo: outbox.audioURL(for: note.id))
        } catch {
            await outbox.remove(note.id)
            state = .failed(String(describing: error))
            return
        }
        current = note
        state = .recording(mode: request, startedAt: note.createdAt)
    }

    /// Ends the running call: stop, save, transcribe, deliver. Does nothing when not recording.
    public func end() async {
        guard case .recording = state, var note = current else { return }
        state = .finishing
        note.duration = await recorder.stop()
        // Saved before transcription, so a kill during recognition keeps the note.
        try? await outbox.save(note)
        state = .transcribing
        let audio = outbox.audioURL(for: note.id)
        if let text = try? await transcriber.transcribe(fileAt: audio) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            note.transcript = trimmed.isEmpty ? nil : trimmed
            try? await outbox.save(note)
        }
        state = .sending
        current = nil
        do {
            try await delivery.deliver(note, audioURL: audio)
            await outbox.remove(note.id)
            state = .sent(note.id)
        } catch {
            state = .savedForLater(note.id)
        }
    }

    /// Ends the running call because the audio session was interrupted
    /// (a phone call, Siri, another app's recording). Same as ``end()``.
    public func interrupted() async {
        await end()
    }

    /// Retries every saved note, oldest first, stopping at the first failure.
    ///
    /// Skips the note being recorded or finished right now. Notes saved before
    /// transcription finished are delivered with whatever transcript they have.
    public func drainOutbox() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        for note in await outbox.pending() where note.id != current?.id {
            do {
                try await delivery.deliver(note, audioURL: outbox.audioURL(for: note.id))
                await outbox.remove(note.id)
            } catch {
                return
            }
        }
    }
}
