import Foundation
import os

/// The scripts every Chromium document gets at its start, and the channels they report on: one
/// list for both ways of installing them. Before fork API 29 each tab installs them over its
/// DevTools session (`Page.addScriptToEvaluateOnNewDocument`, `Runtime.addBinding`); from fork API
/// 29 the runtime installs them once for every browser in the renderer (`cmux_shim_add_document_script`,
/// `cmux_shim_add_page_channel`), so no tab needs a DevTools session (`CEFForkFeatures.rendererPaths`).
///
/// The renderer path reaches cmux's own pages too, so a browser-tab script starts with
/// ``cmuxPageGuard`` and does nothing in a `cmux-page://` document, as Chrome scripts no WebUI page
/// for an extension (`PermissionsData::IsRestrictedUrl`, extensions/common/permissions/permissions_data.cc).
/// Page tabs attach none of their bridges either (``CEFAgentRelay/servesCmuxPage``). The page host
/// relay (``pageHost``) is the other way round: it runs only in a cmux page (``cmuxPageOnlyGuard``).
nonisolated struct CEFDocumentScripts: Equatable, Sendable {
    /// Which documents a script is for.
    enum Scope: Equatable, Sendable, CaseIterable {
        /// Web pages only: the source starts with ``CEFDocumentScripts/cmuxPageGuard``.
        case browserTabs
        /// Every document, cmux pages included (a page tab's first paint).
        case everyDocument
        /// cmux pages only: the source starts with ``CEFDocumentScripts/cmuxPageOnlyGuard`` (the page host relay).
        case cmuxPages
    }

    /// One document-start script.
    struct Script: Equatable, Sendable {
        /// The isolated world it runs in; "" for the page's own world.
        var world: String
        /// What runs: the body inside the guard of its scope (no guard for ``Scope/everyDocument``).
        var source: String
        /// Every frame, cross-origin ones included; false for the main frame only.
        var allFrames: Bool
        var scope: Scope

        init(world: String, body: String, allFrames: Bool, scope: Scope) {
            self.world = world
            source = switch scope {
            case .browserTabs: CEFDocumentScripts.cmuxPageGuard + body + CEFDocumentScripts.cmuxPageGuardEnd
            case .everyDocument: body
            case .cmuxPages: CEFDocumentScripts.cmuxPageOnlyGuard + body + CEFDocumentScripts.cmuxPageGuardEnd
            }
            self.allFrames = allFrames
            self.scope = scope
        }
    }

    /// The start of every browser-tab script: its body runs only outside a cmux page. The origin
    /// covers a cmux page's `about:blank` and `srcdoc` frames, which inherit it.
    static let cmuxPageGuard = "if (location.protocol !== 'cmux-page:' && !String(globalThis.origin).startsWith('cmux-page:')) {\n"
    /// The end of the block ``cmuxPageGuard`` or ``cmuxPageOnlyGuard`` opens.
    static let cmuxPageGuardEnd = "\n}"
    /// The start of a cmux-page script: its body runs only in a `cmux-page://` document.
    static let cmuxPageOnlyGuard = "if (location.protocol === 'cmux-page:') {\n"

    /// The page channel cmux pages call the page host on (``pageHost``).
    static let pageHostChannel = "cmuxPageHost"
    /// The isolated world of ``pageHostChannel`` and its relay.
    static let pageHostWorld = "cmuxPageHost"
    /// The DOM event a cmux page's own world fires for the relay: its `detail` is the post, and the
    /// relay cancels the event once ``pageHostChannel`` took it, so the page sends no binding call.
    static let pageHostEvent = "cmux-page-host-post"

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
    /// The page host relay of a cmux page's main frame; the page-channel path only. A cmux page's
    /// calls then reach the host as `cmuxPost` messages, with no DevTools binding event and no
    /// sender probe, as `chrome.send` reaches `WebUIImpl::OnWebUISend` in one renderer-to-browser
    /// message (content/browser/webui/web_ui_impl.cc). The page's own world has no `cmuxPost`: it
    /// fires ``pageHostEvent`` on its document, and this isolated world posts the event's text.
    var pageHost: [Script]
    /// The App's page host scripts for a cmux page's own world (``CEFPageSchemes/HostScript``: the
    /// WebKit-shaped API over ``pageHostEvent`` and the scripts every page view shares), at document
    /// start before any script of the page, as Chrome binds WebUI in a WebUI renderer before the page
    /// runs; the page-channel path only. With them a cmux page opens no DevTools session for its
    /// host; before them, each page installs its host over its own DevTools session.
    var hostPage: [Script]

    /// - Parameters:
    ///   - post: How the scripts report.
    ///   - hostPage: The App's page host scripts (scope ``Scope/cmuxPages``), installed on the page-channel path only.
    init(post: Post, hostPage: [Script] = []) {
        self.hostPage = post == .pageChannel ? hostPage : []
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
        pageHost = post == .pageChannel
            ? [Script(world: Self.pageHostWorld,
                      body: Self.pageHostRelay(post: post.send(Self.pageHostChannel, "stamped"), ready: post.ready(Self.pageHostChannel)),
                      allFrames: false, scope: .cmuxPages)]
            : []
    }

    /// Every script, in install order.
    var all: [Script] { media + verification + firstPaint + pageHost + hostPage }

    /// The longest text the relay posts, in UTF-16 units: at most 3 UTF-8 bytes each, so every post
    /// it sends fits ``CEFPageMessage/maxPageHostPayloadBytes`` and none is dropped on arrival.
    static let pageHostRelayMaxCharacters = CEFPageMessage.maxPageHostPayloadBytes / 3

    /// The relay from ``pageHostEvent`` to ``pageHostChannel``: `post` sends `stamped`, the event's
    /// text after its document's URL and a newline (``pageHostPost(_:)``); `ready` says the channel
    /// exists. The relay reads the URL in its isolated world, which the page's own world cannot
    /// change, so the host judges each post by the document that sent it, not by the last commit it
    /// heard. An event it did not post stays uncancelled, and the page sends that post on its
    /// DevTools binding instead (a channel the shim refused, a text over the channel's size).
    static func pageHostRelay(post: String, ready: String) -> String {
        """
        document.addEventListener('\(pageHostEvent)', (event) => {
          const text = event.detail;
          if (typeof text !== 'string' || !(\(ready))) return;
          const stamped = location.href + '\\n' + text;
          if (stamped.length > \(pageHostRelayMaxCharacters)) return;
          try { \(post); } catch (_) { return; }
          event.preventDefault();
          event.stopImmediatePropagation();
        }, true);
        """
    }

    /// One post of the relay (``pageHostRelay(post:ready:)``): the sending document's URL and the
    /// page's text. Nil when the stamp is missing or is no URL. A URL has no raw newline.
    static func pageHostPost(_ payload: String) -> (sender: URL, text: String)? {
        guard let newline = payload.firstIndex(of: "\n"), let sender = URL(string: String(payload[..<newline])) else { return nil }
        return (sender, String(payload[payload.index(after: newline)...]))
    }

    /// Installs every script and channel for every browser (fork API 29). Returns the names the
    /// shim refused (empty when all went in).
    @MainActor func installInRenderer(_ shim: CEFShimLibrary) -> [String] { installAll(shim).refused }

    /// Installs them (``installInRenderer(_:)``) and logs what the shim refused.
    ///
    /// - Returns: True when the cmux page host went in whole (the page host channel, its relay and
    ///   every ``hostPage`` script), so a cmux page may skip DevTools; false without ``hostPage``.
    @MainActor func install(_ shim: CEFShimLibrary, logger: Logger) -> Bool {
        let result = installAll(shim)
        if !result.refused.isEmpty { logger.error("document scripts refused by the shim: \(result.refused.joined(separator: ", "), privacy: .public)") }
        return !hostPage.isEmpty && result.pageHostWhole
    }

    @MainActor private func installAll(_ shim: CEFShimLibrary) -> (refused: [String], pageHostWhole: Bool) {
        guard let addPageChannel = shim.addPageChannel, let addDocumentScript = shim.addDocumentScript else {
            return (["shim has no renderer paths"], false)
        }
        var refused: [String] = []
        var pageHostWhole = true
        for channel in CEFPageMessage.Channel.allCases where addPageChannel(channel.world, channel.name) != 1 {
            refused.append("channel \(channel.name)")
            if channel == .pageHost { pageHostWhole = false }
        }
        let firstPageHost = all.count - pageHost.count - hostPage.count
        for (index, script) in all.enumerated() where addDocumentScript(script.world, script.source, script.allFrames ? 1 : 0, 1) != 1 {
            refused.append("script \(index) (\(script.world.isEmpty ? "page" : script.world))")
            if index >= firstPageHost { pageHostWhole = false }
        }
        return (refused, pageHostWhole)
    }
}
