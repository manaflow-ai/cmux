import CmuxNextHibernation
import CmuxNextWakeups
import Foundation
import WebKit

/// WebKit's own media state of one page's WKWebView, held as the page's `audible` and `capture` keep
/// reasons (``PageKeepReasons/begin(_:)``): the camera or microphone in use (`cameraCaptureState`,
/// `microphoneCaptureState`) and sound playing (WebKit's `_isPlayingAudio`, the state Safari's tab
/// audio indicator reads, read only where the view answers it). As Chrome, the browser side observes
/// sound and devices itself; page script cannot claim either (freezing_policy.cc reads
/// `PageNode::IsAudible` and the capture observers, chrome/browser/performance_manager/policies/).
/// A hidden page that plays or captures stays visible to WebKit (PageWebView+HostHidden.swift) and is
/// not frozen (``PageLifecycle``).
///
/// ```swift
/// media = PageWebKitMediaWatch(view: view, keepReasons: page.keepReasons)
/// ```
@MainActor
final class PageWebKitMediaWatch: NSObject {
    /// What WebKit says the view plays or captures now.
    typealias Read = @MainActor (WKWebView) -> Set<PageKeepReasons.KeepReason>

    /// WebKit's KVO-compliant private key for "the page plays audible sound".
    static let playingAudioKey = "_isPlayingAudio"
    /// The public keys of the camera and microphone in use.
    static let captureKeys = ["cameraCaptureState", "microphoneCaptureState"]

    private let view: WKWebView
    /// The keys observed on ``view``; removed in `deinit`.
    private let keys: [String]
    private weak var keepReasons: PageKeepReasons?
    private let read: Read
    /// The reasons this watch holds on ``keepReasons`` now.
    private(set) var held: Set<PageKeepReasons.KeepReason> = []

    /// Observes `view` and holds what it plays or captures now.
    ///
    /// - Parameters:
    ///   - view: The page's WebKit view (held: the observers are removed from it in `deinit`).
    ///   - keepReasons: The page's keep reasons.
    ///   - read: What the view plays or captures (tests pass their own).
    init(view: WKWebView, keepReasons: PageKeepReasons, read: @escaping Read = PageWebKitMediaWatch.webKitState) {
        self.view = view
        self.keepReasons = keepReasons
        self.read = read
        keys = Self.captureKeys + (Self.answersPlayingAudio(view) ? [Self.playingAudioKey] : [])
        super.init()
        // raw-observer-allow: WKWebView reports capture and sound only through KVO (no notice); it is this page's own view
        for key in keys { view.addObserver(self, forKeyPath: key, options: [], context: nil) }
        update()
    }

    // cx-t7hu: not an isolated deinit (its runtime hop traps inside an action's task-local scope). KVO
    // removal is thread-safe, as NSKeyValueObservation's invalidate on any thread relies on.
    nonisolated deinit {
        for key in keys { view.removeObserver(self, forKeyPath: key) }
    }

    /// What `view` plays or captures, from WebKit.
    static func webKitState(_ view: WKWebView) -> Set<PageKeepReasons.KeepReason> {
        var reasons: Set<PageKeepReasons.KeepReason> = []
        if view.cameraCaptureState != .none || view.microphoneCaptureState != .none { reasons.insert(.capture) }
        // crash-allow: KVC of WebKit's private key, read only after answersPlayingAudio confirmed the view has it (no NSUnknownKeyException).
        if answersPlayingAudio(view), view.value(forKey: playingAudioKey) as? Bool == true { reasons.insert(.audible) }
        return reasons
    }

    /// Whether this WebKit has the private sound key.
    private static func answersPlayingAudio(_ view: WKWebView) -> Bool {
        view.responds(to: NSSelectorFromString(playingAudioKey))
    }

    /// Holds what the view plays or captures now and ends what stopped; each change reaches the page's
    /// lifecycle and host hide through ``PageKeepReasons``.
    func update() {
        let now = read(view)
        guard now != held, let keepReasons else { return }
        let started = now.subtracting(held), ended = held.subtracting(now)
        held = now
        for reason in started { keepReasons.begin(reason) }
        for reason in ended { keepReasons.end(reason) }
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // main-hop-allow: WebKit changes these on the main thread, so the change applies inline in that turn; only an off-main change hops
        MainDelivery().run { [weak self] in self?.update() }
    }
}
