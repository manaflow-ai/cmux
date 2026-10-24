import Foundation

/// The scripts every Chromium document gets at its start, and the channels they report on: one
/// list for both ways of installing them. Before fork API 29 each tab installs them over its
/// DevTools session (`Page.addScriptToEvaluateOnNewDocument`, `Runtime.addBinding`); from fork API
/// 29 the runtime installs them once for every browser in the renderer (`cmux_shim_add_document_script`,
/// `cmux_shim_add_page_channel`), so no tab needs a DevTools session (`CEFForkFeatures.rendererPaths`).
nonisolated struct CEFDocumentScripts: Equatable, Sendable {
    /// One document-start script.
    struct Script: Equatable, Sendable {
        /// The isolated world it runs in; "" for the page's own world.
        var world: String
        var source: String
        /// Every frame, cross-origin ones included; false for the main frame only.
        var allFrames: Bool
    }

    /// How a script reports on `channel`: a DevTools binding of that name, or the fork's `cmuxPost`.
    enum Post: Equatable, Sendable {
        case binding
        case pageChannel

        /// The statement that posts `value` on `channel`.
        func send(_ channel: String, _ value: String) -> String {
            switch self {
            case .binding: "\(channel)(\(value))"
            case .pageChannel: "cmuxPost('\(channel)', \(value))"
            }
        }

        /// The expression that says the channel exists yet.
        func ready(_ channel: String) -> String {
            switch self {
            case .binding: "typeof \(channel) === 'function'"
            case .pageChannel: "typeof cmuxPost === 'function'"
            }
        }
    }

    /// The media hub: observer (media world), page actions recorder, page busy recorder and the
    /// protected media probe (page world), protected media relay (media world).
    var media: [Script]
    /// The email verification detector (its own world, main frame).
    var verification: [Script]
    /// The first contentful paint report (its own world, main frame); the page-channel path only:
    /// the DevTools path reads Page.lifecycleEvent instead (`CEFFirstPaintBridge`).
    var firstPaint: [Script]

    init(post: Post) {
        let mediaChannel = BrowserMediaState.channel
        let protectedChannel = BrowserProtectedMedia.channel
        media = [
            Script(world: BrowserMediaState.world,
                   source: BrowserMediaState.observerScript(post: post.send(mediaChannel, "JSON.stringify(message)"), ready: post.ready(mediaChannel)),
                   allFrames: true),
            Script(world: "", source: BrowserMediaState.actionsScript, allFrames: true),
            Script(world: "", source: BrowserPageBusy.recorderScript, allFrames: true),
            // A refused Widevine request reopens the tab in WebKit (BrowserProtectedMedia).
            Script(world: "", source: BrowserProtectedMedia.probeScript, allFrames: true),
            Script(world: BrowserMediaState.world,
                   source: BrowserProtectedMedia.relayScript(post: post.send(protectedChannel, "name"), ready: post.ready(protectedChannel)),
                   allFrames: true),
        ]
        let verifyChannel = VerificationPageScripts.channel
        verification = [Script(world: VerificationPageScripts.world,
                               source: VerificationPageScripts.detectorScript(post: post.send(verifyChannel, "JSON.stringify(report)"),
                                                                              ready: post.ready(verifyChannel)),
                               allFrames: false)]
        let paintChannel = BrowserFirstPaintScript.channel
        firstPaint = post == .pageChannel
            ? [Script(world: BrowserFirstPaintScript.world,
                      source: BrowserFirstPaintScript.source(post: post.send(paintChannel, "String(report)"), ready: post.ready(paintChannel)),
                      allFrames: false)]
            : []
    }

    /// Every script, in install order.
    var all: [Script] { media + verification + firstPaint }

    /// Installs every script and channel for every browser (fork API 29). Returns the names the
    /// shim refused (empty when all went in).
    @MainActor func installInRenderer(_ shim: CEFShimLibrary) -> [String] {
        guard let addPageChannel = shim.addPageChannel, let addDocumentScript = shim.addDocumentScript else { return ["shim has no renderer paths"] }
        var refused: [String] = []
        for channel in CEFPageMessage.Channel.allCases where addPageChannel(channel.world, channel.name) != 1 {
            refused.append("channel \(channel.name)")
        }
        for (index, script) in all.enumerated() where addDocumentScript(script.world, script.source, script.allFrames ? 1 : 0, 1) != 1 {
            refused.append("script \(index) (\(script.world.isEmpty ? "page" : script.world))")
        }
        return refused
    }
}
