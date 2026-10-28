import Foundation

/// A message a page posted on one of cmux's channels (`cmuxPost(channel, string)` in a named
/// isolated world, fork API 29). Untrusted data: a compromised renderer can post anything on any
/// channel, so only known channels pass, the payload is bounded, and receivers parse it as data.
nonisolated struct CEFPageMessage: Equatable, Sendable {
    /// The channels cmux reads, each with the isolated world it lives in.
    enum Channel: Equatable, Sendable, CaseIterable {
        /// `BrowserMediaState` reports.
        case media
        /// `BrowserProtectedMedia` refusals.
        case protectedMedia
        /// `VerificationPageScripts` reports (main frame only).
        case verification
        /// `BrowserFirstPaintScript` (main frame only).
        case firstPaint

        var name: String {
            switch self {
            case .media: BrowserMediaState.channel
            case .protectedMedia: BrowserProtectedMedia.channel
            case .verification: VerificationPageScripts.channel
            case .firstPaint: BrowserFirstPaintScript.channel
            }
        }

        var world: String {
            switch self {
            case .media, .protectedMedia: BrowserMediaState.world
            case .verification: VerificationPageScripts.world
            case .firstPaint: BrowserFirstPaintScript.world
            }
        }

        /// Messages from child frames are dropped.
        var mainFrameOnly: Bool { self == .verification || self == .firstPaint }
    }

    /// The largest payload accepted. A media report is under 2 KB; more is not cmux's script.
    static let maxPayloadBytes = 64 * 1024

    let channel: Channel
    let payload: String

    /// Nil for an unknown channel, an oversized payload, or a child frame on a main-frame channel.
    init?(channel name: String, payload: String, mainFrame: Bool) {
        guard let channel = Channel.allCases.first(where: { $0.name == name }), payload.utf8.count <= Self.maxPayloadBytes,
              mainFrame || !channel.mainFrameOnly else { return nil }
        self.channel = channel
        self.payload = payload
    }
}
