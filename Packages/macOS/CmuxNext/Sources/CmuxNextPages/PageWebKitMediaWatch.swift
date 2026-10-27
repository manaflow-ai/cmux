import CmuxNextHibernation
import Foundation
import WebKit

/// Whether one page's WKWebView plays sound, held as the page's `audible` keep reason
/// (``PageKeepReasons/begin(_:)``): a media element that plays unmuted, reported by ``observerScript``
/// from the host's own content world, so page script can neither post to its handler nor claim sound.
/// As in Chrome, the browser side observes sound itself; the page never reports it (freezing_policy.cc
/// reads `PageNode::IsAudible`, chrome/browser/performance_manager/policies/). A capture is the page's
/// own `capture` reason (the composer's, ``PageKeepReasons/pageSettable``): no cmux page opens the camera
/// or microphone through WebKit. A hidden page that plays stays visible to WebKit
/// (PageWebView+HostHidden.swift) and is not frozen (``PageLifecycle``).
///
/// ```swift
/// media = PageWebKitMediaWatch(view: view, keepReasons: page.keepReasons)
/// ```
@MainActor
final class PageWebKitMediaWatch {
    /// The content world of ``observerScript`` and its handler: the host's, not the page's.
    static let world = WKContentWorld.world(name: "cmux.pageMedia")
    /// The handler ``observerScript`` posts to in ``world``.
    static let channel = "cmuxPageMedia"

    /// Posts `true` when a media element of the document starts playing audible sound and `false` when
    /// none does any more; `false` once at document start, so a new document starts silent. Media events
    /// do not bubble, so the document hears them in the capture phase; a playing element removed from the
    /// document pauses with no event the document hears, so removals are checked while sound plays.
    static let observerScript = """
    (() => {
      const post = (on) => window.webkit.messageHandlers.\(channel).postMessage(on);
      let audible = false;
      const check = () => {
        const now = Array.from(document.querySelectorAll('audio, video'))
          .some((media) => !media.paused && !media.ended && !media.muted && media.volume > 0);
        if (now === audible) return;
        audible = now;
        post(now);
      };
      for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied']) {
        document.addEventListener(type, check, true);
      }
      new MutationObserver(() => { if (audible) check(); }).observe(document, { childList: true, subtree: true });
      post(false);
    })();
    """

    private weak var keepReasons: PageKeepReasons?
    /// Whether this watch holds `audible` on ``keepReasons`` now.
    private(set) var holdsSound = false

    /// Installs ``observerScript`` and its handler on `view`'s configuration.
    ///
    /// - Parameters:
    ///   - view: The page's WebKit view.
    ///   - keepReasons: The page's keep reasons.
    init(view: WKWebView, keepReasons: PageKeepReasons) {
        self.keepReasons = keepReasons
        let controller = view.configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.observerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        // A new engine on the same configuration (a rebuilt view) replaces the old handler: a second add of one name raises.
        controller.removeScriptMessageHandler(forName: Self.channel, contentWorld: Self.world)
        controller.add(PageMediaRelay(watch: self), contentWorld: Self.world, name: Self.channel)
    }

    /// ``observerScript`` reported that the document plays audible sound (`true`) or no longer does; the
    /// change reaches the page's lifecycle and host hide through ``PageKeepReasons``.
    func soundDidChange(_ playing: Bool) {
        guard playing != holdsSound, let keepReasons else { return }
        holdsSound = playing
        if playing { keepReasons.begin(.audible) } else { keepReasons.end(.audible) }
    }
}

/// ``PageWebKitMediaWatch/observerScript``'s handler: its main-frame messages, to its watch (held weakly).
private final class PageMediaRelay: NSObject, WKScriptMessageHandler {
    private weak var watch: PageWebKitMediaWatch?

    init(watch: PageWebKitMediaWatch) {
        self.watch = watch
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let playing = message.body as? Bool else { return }
        watch?.soundDidChange(playing)
    }
}
