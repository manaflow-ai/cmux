import Foundation
import WebRTC

/// libwebrtc field trials for this process. libwebrtc reads them process-wide, so every
/// peer connection factory in the app calls ``prepare()`` before it is made (the screen
/// stream's here, the iPhone's Chief call link): the first call sets them, later calls do
/// nothing, and whichever factory comes first already sees them.
public struct WebRTCFieldTrials {
    public init() {}
    /// Playout delay 0 on both ends: a decoded video frame is shown at once instead of being
    /// held in the jitter buffer for smooth playback. A screen is not a film: the newest pixels
    /// matter, not an even cadence. The receive trial covers this build's viewer whatever the
    /// host sends; the send trial puts min 0, max 0 in the playout-delay header extension, so a
    /// viewer from before this change also renders at once. Audio is not affected.
    static let trials: [String: String] = [
        "WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0",
        "WebRTC-ForceSendPlayoutDelay": "min_ms:0,max_ms:0",
    ]

    /// Sets ``trials`` once per process (lazy static init is atomic). Call before creating any
    /// `RTCPeerConnectionFactory`.
    public static func prepare() { _ = applied }

    private static let applied: Bool = {
        (Setter.self as any Applying.Type).apply()
        return true
    }()
}

/// libwebrtc's only Objective-C setter for field trials is marked deprecated; calling it from a
/// deprecated implementation reached through a protocol keeps the package free of warnings.
private protocol Applying { static func apply() }
private enum Setter: Applying {
    @available(*, deprecated, message: "libwebrtc's only Objective-C entry point for field trials")
    static func apply() { RTCInitFieldTrialDictionary(WebRTCFieldTrials.trials) }
}
