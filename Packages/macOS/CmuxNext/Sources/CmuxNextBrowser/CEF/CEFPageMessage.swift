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
        /// A cmux page's calls to its page host (``CEFDocumentScripts/pageHost``, main frame only).
        case pageHost

        var name: String {
            switch self {
            case .media: BrowserMediaState.channel
            case .protectedMedia: BrowserProtectedMedia.channel
            case .verification: VerificationPageScripts.channel
            case .firstPaint: BrowserFirstPaintScript.channel
            case .pageHost: CEFDocumentScripts.pageHostChannel
            }
        }

        var world: String {
            switch self {
            case .media, .protectedMedia: BrowserMediaState.world
            case .verification: VerificationPageScripts.world
            case .firstPaint: BrowserFirstPaintScript.world
            case .pageHost: CEFDocumentScripts.pageHostWorld
            }
        }

        /// Messages from child frames are dropped.
        var mainFrameOnly: Bool { self != .media && self != .protectedMedia }

        /// A cmux page tab reads it: the first paint, whose script runs in every document
        /// (``CEFDocumentScripts/Scope/everyDocument``), and the page host relay, which runs only in
        /// cmux pages. The others are browser tabs' own.
        var servesCmuxPages: Bool { self == .firstPaint || self == .pageHost }

        /// Browser tabs read it; a browser tab's post on a channel of cmux pages only is dropped.
        var servesBrowserTabs: Bool { self != .pageHost }

        /// The largest payload accepted: a media report is under 2 KB, more is not cmux's script;
        /// a page host post carries what the page's binding call carries (`ChromiumPageHostBridge.maximumPayloadBytes`).
        var maxPayloadBytes: Int { self == .pageHost ? CEFPageMessage.maxPageHostPayloadBytes : CEFPageMessage.maxPayloadBytes }
    }

    /// The largest payload accepted on a browser-tab channel and the first paint.
    static let maxPayloadBytes = 64 * 1024
    /// The largest page host post (4 MiB, as the page's binding call); the Chromium Host sends one
    /// over 64 KiB as a sealed shared memory region.
    static let maxPageHostPayloadBytes = 4 << 20

    let channel: Channel
    let payload: String

    /// Nil for an unknown channel, an oversized payload, or a child frame on a main-frame channel.
    init?(channel name: String, payload: String, mainFrame: Bool) {
        guard let channel = Channel.allCases.first(where: { $0.name == name }), payload.utf8.count <= channel.maxPayloadBytes,
              mainFrame || !channel.mainFrameOnly else { return nil }
        self.channel = channel
        self.payload = payload
    }
}
