public import Foundation
import Observation

/// The app's one open Voice Room: opens a ``VoiceRoomSession`` against an address with the on-device
/// engines, shares the microphone through ``DictationMicrophoneClaims``, and stops the room when its
/// Labs switch turns off.
///
/// ```swift
/// let host = VoiceRoomHost(frames: framesFolder)
/// host.open(address) { settings.snapshot.voiceRoom }
/// ```
@MainActor
public final class VoiceRoomHost {
    private let frames: URL?
    private let claims: DictationMicrophoneClaims
    private let makeSession: @MainActor (VoiceRoomAddress, URL?) -> VoiceRoomSession
    private var session: VoiceRoomSession?
    private var address: VoiceRoomAddress?

    /// - Parameters:
    ///   - frames: Where screen keyframes stay on this Mac; nil keeps none.
    ///   - claims: The app's microphone owners.
    ///   - makeSession: Makes the session for an address; tests pass fakes.
    public init(frames: URL?, claims: DictationMicrophoneClaims = .shared,
                makeSession: @escaping @MainActor (VoiceRoomAddress, URL?) -> VoiceRoomSession = { VoiceRoomHost.systemSession($0, frames: $1) }) {
        self.frames = frames
        self.claims = claims
        self.makeSession = makeSession
    }

    /// True while a room listens or is paused by its people.
    public var isOpen: Bool { session?.isOpen == true }

    /// Opens `address`; a session already open there stays, another address replaces it.
    ///
    /// - Parameters:
    ///   - address: The room.
    ///   - allowed: The Labs switch, read under Observation: when it turns false the room stops.
    public func open(_ address: VoiceRoomAddress, allowed: @escaping @MainActor () -> Bool) {
        if isOpen, self.address == address { return }
        session?.stop()
        let made = makeSession(address, frames)
        session = made
        self.address = address
        claims.claim(self) { [weak made] in made?.yieldMicrophone() }
        made.start()
        follow(allowed)
    }

    /// Stops the room and gives the microphone back.
    public func stop() {
        session?.stop()
        session = nil
        address = nil
        claims.release(self)
    }

    private func follow(_ allowed: @escaping @MainActor () -> Bool) {
        withObservationTracking { _ = allowed() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isOpen else { return }
                if allowed() { self.follow(allowed) } else { self.stop() }
            }
        }
    }

    /// The real session: on-device speech (a recorded clip in Debug when
    /// `CMUX_NEXT_DICTATION_AUDIO_FILE` names one), HTTP lines, the room's socket and the screen.
    public static func systemSession(_ address: VoiceRoomAddress, frames: URL?) -> VoiceRoomSession {
        VoiceRoomSession(
            dictation: {
                #if DEBUG
                if let recorded = DictationSession.recorded() { return recorded }
                #endif
                return DictationSession()
            },
            poster: VoiceRoomHTTPPoster(address: address),
            events: VoiceRoomWebSocketEvents(address: address),
            screen: VoiceRoomScreenReader(frames: frames)
        )
    }
}
