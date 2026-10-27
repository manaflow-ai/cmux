import CmuxNextHibernation
import CmuxNextWakeups
import Foundation
import WebKit

/// What one page's WKWebView plays or captures, held as the page's `audible` and `capture` keep reasons
/// (``PageKeepReasons/begin(_:)``): the camera or microphone in use (WebKit's `cameraCaptureState` and
/// `microphoneCaptureState`, through KVO) and sound playing (a media element that plays unmuted, reported
/// by ``observerScript`` from the host's own content world, so page script can neither post to its handler
/// nor claim sound). As in Chrome, the browser side observes sound and devices itself; the page never
/// reports them (freezing_policy.cc reads `PageNode::IsAudible` and the capture observers,
/// chrome/browser/performance_manager/policies/). A hidden page that plays or captures stays visible to
/// WebKit (PageWebView+HostHidden.swift) and is not frozen (``PageLifecycle``).
///
/// ```swift
/// media = PageWebKitMediaWatch(view: view, keepReasons: page.keepReasons)
/// ```
@MainActor
final class PageWebKitMediaWatch {
    /// Whether a view captures from the camera or microphone now (tests pass their own).
    typealias ReadCapture = @MainActor (WKWebView) -> Bool

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
    private let readCapture: ReadCapture
    private var observations: [NSKeyValueObservation] = []
    /// The reasons this watch holds on ``keepReasons`` now.
    private(set) var held: Set<PageKeepReasons.KeepReason> = []
    private var playsSound = false

    /// Observes `view` and holds what it plays or captures now.
    ///
    /// - Parameters:
    ///   - view: The page's WebKit view.
    ///   - keepReasons: The page's keep reasons.
    ///   - readCapture: Whether the view captures now (``webKitCapture(_:)``).
    init(view: WKWebView, keepReasons: PageKeepReasons, readCapture: @escaping ReadCapture = PageWebKitMediaWatch.webKitCapture) {
        self.keepReasons = keepReasons
        self.readCapture = readCapture
        let changed: @Sendable (WKWebView, NSKeyValueObservedChange<WKMediaCaptureState>) -> Void = { [weak self] view, _ in
            // main-hop-allow: WebKit changes its capture state on the main thread, so the change applies inline in that turn; only an off-main change hops
            MainDelivery().run { self?.captureDidChange(view) }
        }
        // raw-observer-allow: WKWebView reports camera and microphone use only through KVO (no notice); it is this page's own view
        observations = [view.observe(\.cameraCaptureState, changeHandler: changed),
                        view.observe(\.microphoneCaptureState, changeHandler: changed)]
        let controller = view.configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.observerScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        // A new engine on the same configuration (a rebuilt view) replaces the old handler: a second add of one name raises.
        controller.removeScriptMessageHandler(forName: Self.channel, contentWorld: Self.world)
        controller.add(PageMediaRelay(watch: self), contentWorld: Self.world, name: Self.channel)
        captureDidChange(view)
    }

    /// Whether `view` uses the camera or microphone, from WebKit.
    static func webKitCapture(_ view: WKWebView) -> Bool {
        view.cameraCaptureState != .none || view.microphoneCaptureState != .none
    }

    /// ``observerScript`` reported that the document plays audible sound (`true`) or no longer does.
    func soundDidChange(_ playing: Bool) {
        playsSound = playing
        apply(capturing: held.contains(.capture))
    }

    private func captureDidChange(_ view: WKWebView) {
        apply(capturing: readCapture(view))
    }

    /// Holds what plays or captures now and ends what stopped; each change reaches the page's lifecycle
    /// and host hide through ``PageKeepReasons``.
    private func apply(capturing: Bool) {
        var now: Set<PageKeepReasons.KeepReason> = []
        if playsSound { now.insert(.audible) }
        if capturing { now.insert(.capture) }
        guard now != held, let keepReasons else { return }
        let started = now.subtracting(held), ended = held.subtracting(now)
        held = now
        for reason in started { keepReasons.begin(reason) }
        for reason in ended { keepReasons.end(reason) }
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
