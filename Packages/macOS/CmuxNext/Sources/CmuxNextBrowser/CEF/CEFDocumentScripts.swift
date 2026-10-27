import Foundation

/// The scripts every Chromium document gets at its start, and the channels they report on: one
/// list for both ways of installing them. Before fork API 29 each tab installs them over its
/// DevTools session (`Page.addScriptToEvaluateOnNewDocument`, `Runtime.addBinding`); from fork API
/// 29 the runtime installs them once for every browser in the renderer (`cmux_shim_add_document_script`,
/// `cmux_shim_add_page_channel`), so no tab needs a DevTools session (`CEFForkFeatures.rendererPaths`).
///
/// The renderer path reaches cmux's own pages too, so a browser-tab script starts with
/// ``cmuxPageGuard`` and does nothing in a `cmux-page://` document, as Chrome scripts no WebUI page
/// for an extension (`PermissionsData::IsRestrictedUrl`, extensions/common/permissions/permissions_data.cc).
/// Page tabs attach none of their bridges either (``CEFAgentRelay/servesCmuxPage``).
nonisolated struct CEFDocumentScripts: Equatable, Sendable {
    /// Which documents a script is for.
    enum Scope: Equatable, Sendable, CaseIterable {
        /// Web pages only: the source starts with ``CEFDocumentScripts/cmuxPageGuard``.
        case browserTabs
        /// Every document, cmux pages included (a page tab's first paint).
        case everyDocument
    }

    /// One document-start script.
    struct Script: Equatable, Sendable {
        /// The isolated world it runs in; "" for the page's own world.
        var world: String
        /// What runs: the body inside the cmux-page guard for ``Scope/browserTabs``, the body itself otherwise.
        var source: String
        /// Every frame, cross-origin ones included; false for the main frame only.
        var allFrames: Bool
        var scope: Scope

        init(world: String, body: String, allFrames: Bool, scope: Scope) {
            self.world = world
            source = scope == .browserTabs ? CEFDocumentScripts.cmuxPageGuard + body + CEFDocumentScripts.cmuxPageGuardEnd : body
            self.allFrames = allFrames
            self.scope = scope
        }
    }

    /// The start of every browser-tab script: its body runs only outside a cmux page. The origin
    /// covers a cmux page's `about:blank` and `srcdoc` frames, which inherit it.
    static let cmuxPageGuard = "if (location.protocol !== 'cmux-page:' && !String(globalThis.origin).startsWith('cmux-page:')) {\n"
    /// The end of the block ``cmuxPageGuard`` opens.
    static let cmuxPageGuardEnd = "\n}"

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
                   body: BrowserMediaState.observerScript(post: post.send(mediaChannel, "JSON.stringify(message)"), ready: post.ready(mediaChannel)),
                   allFrames: true, scope: .browserTabs),
            Script(world: "", body: BrowserMediaState.actionsScript, allFrames: true, scope: .browserTabs),
            Script(world: "", body: BrowserPageBusy.recorderScript, allFrames: true, scope: .browserTabs),
            // A refused Widevine request reopens the tab in WebKit (BrowserProtectedMedia).
            Script(world: "", body: BrowserProtectedMedia.probeScript, allFrames: true, scope: .browserTabs),
            Script(world: BrowserMediaState.world,
                   body: BrowserProtectedMedia.relayScript(post: post.send(protectedChannel, "name"), ready: post.ready(protectedChannel)),
                   allFrames: true, scope: .browserTabs),
        ]
        let verifyChannel = VerificationPageScripts.channel
        verification = [Script(world: VerificationPageScripts.world,
                               body: VerificationPageScripts.detectorScript(post: post.send(verifyChannel, "JSON.stringify(report)"),
                                                                            ready: post.ready(verifyChannel)),
                               allFrames: false, scope: .browserTabs)]
        let paintChannel = BrowserFirstPaintScript.channel
        // A page tab's first paint ends its loading background and its chat open's stages too.
        firstPaint = post == .pageChannel
            ? [Script(world: BrowserFirstPaintScript.world,
                      body: BrowserFirstPaintScript.source(post: post.send(paintChannel, "String(report)"), ready: post.ready(paintChannel)),
                      allFrames: false, scope: .everyDocument)]
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
