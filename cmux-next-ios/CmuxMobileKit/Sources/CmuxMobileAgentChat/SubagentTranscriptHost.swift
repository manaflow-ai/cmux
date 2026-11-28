#if os(iOS)
import SwiftUI
import UIKit

/// A subagent's transcript on the chat's transcript list (`ChatTranscriptList`, a collection view
/// of measured rows): the reader's place holds while rows above them change height, which a
/// SwiftUI lazy stack did not do (it reset the transcript to its top, and a 15,000 pt answer
/// stalled its layout). This host does only what the chat's controller does that a subagent
/// screen needs, without its composer and keyboard: where the transcript opens, and following
/// its end while the subagent runs (`SubagentFollow`). Holding the reader stays in the list's
/// layout.
@MainActor
final class SubagentTranscriptHost: UIViewController, UIScrollViewDelegate {
    let list: ChatTranscriptList
    private let running: () -> Bool
    /// Whether the end is followed (the reader on it, by their own scroll or at rest there).
    private(set) var follow: SubagentFollow
    /// The first layout with rows placed the transcript (its top, or its end while running).
    private(set) var positioned = false
    private var contentHeight: CGFloat = 0
    let probe: FollowProbe?
    /// Within this of the end counts as on it (a fling that stops just short while a row lands).
    static let endBand: CGFloat = 60

    /// `windowed`: the open shows the rows where it opens and grows a chunk a frame (off: every
    /// row at once, as tests compare against).
    init(store: AgentChatStore, subagentID: String, probe: FollowProbe? = nil, windowed: Bool = true) {
        let source = ChatTranscriptSource.subagent(subagentID, store: store)
        let running = { source.runningTurn() != nil }
        self.running = running
        self.probe = probe
        // Its own surface: following and disclosures are this transcript's, not the chat's.
        let surface = AgentChatSurface()
        // Laid out at once by this host: nothing is built before the width comes.
        list = ChatTranscriptList(store: store, surface: surface, source: source, waitsForWidth: true)
        list.foldsWork = false
        // Opens on the end of a running subagent (following it), on the top of a finished one.
        follow = SubagentFollow(follows: running())
        // The open shows the rows where it opens; the rest come a chunk a frame (`fill`).
        source.window?.atEnd = running()
        source.window?.enabled = windowed
        super.init(nibName: nil, bundle: nil)
        list.scrollDelegate = self
        list.defersLandings = { [weak self] in self?.defersLandings ?? false }
        #if DEBUG
        list.frameStamp = { [weak self] in self?.frames ?? 0 }
        #endif
        // A finished transcript opens at its top: its newest rows are not primed on the main thread.
        list.opensOnNewest = { [weak self] in self?.follow.follows ?? true }
        // A row above the reader that changes height moves nothing they see, unless the end of a
        // running subagent is followed (then the end stays in place).
        list.layout.followsBottom = { [weak self] in
            guard let self else { return false }
            return self.follow.sizeChangeAnchor(running: self.running()) == .bottom
        }
        list.collectionView.didLayout = { [weak self] in self?.laidOut() }
        // The list places itself where it opens before its first cells are made.
        list.openingOffset = { [weak self] height in
            guard let self else { return 0 }
            let scrollView = self.list.collectionView
            let top = -scrollView.adjustedContentInset.top
            let bottom = max(top, height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
            self.positioned = true
            self.fill()
            return self.follow.follows ? bottom : top
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The end is kept in view: the reader is on it and the subagent runs.
    var follows: Bool { follow.follows && running() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let collectionView = list.collectionView
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.contentInset = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        collectionView.alwaysBounceVertical = true
        view.addSubview(collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        list.boundsMayHaveChanged()
    }

    private var bottomOffset: CGFloat {
        let scrollView = list.collectionView
        return max(-scrollView.adjustedContentInset.top,
                   scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
    }

    private var topOffset: CGFloat { -list.collectionView.adjustedContentInset.top }

    private var onEnd: Bool { list.collectionView.contentOffset.y >= bottomOffset - Self.endBand }

    /// After each layout pass of the list: the opening place once, then the end while followed.
    private func laidOut() {
        let scrollView = list.collectionView
        guard scrollView.bounds.height > 0, scrollView.contentSize.height > 0 else { return }
        let grew = scrollView.contentSize.height > contentHeight
        contentHeight = scrollView.contentSize.height
        // Under the finger nothing moves the transcript but the finger.
        guard !scrollView.isTracking, !scrollView.isDragging else { return }
        if !positioned {
            positioned = true
            scrollView.contentOffset.y = follow.follows ? bottomOffset : topOffset
            fill()
            return
        }
        guard !scrollView.isDecelerating else { return }
        // At rest the reader's place decides whether the end is followed; while it is, the end is
        // kept exactly (rows measured after the first layout grow the content below it).
        _ = follow.changed(atEnd: onEnd, grew: grew, scrolling: false, running: running())
        if follows, abs(scrollView.contentOffset.y - bottomOffset) > 0.5 {
            scrollView.contentOffset.y = bottomOffset
        }
        if let probe, follows {
            probe.sample(gap: max(0, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
                                      - (scrollView.contentOffset.y + scrollView.bounds.height)), grew: grew)
        }
    }

    /// Chunks of the transcript's rows, one per display frame, until every row is shown: below a
    /// finished one's top, above a running one's end (the list keeps the reader's rows where they
    /// are). Driven by the display, so a frame never carries two chunks (#47189 r8: a 16 ms sleep
    /// is not the frame, and two chunks landed in one about a time in three).
    private var link: CADisplayLink?
    /// Display frames the fill has run (a deferred landing waits at most one).
    private(set) var frames = 0
    /// Chunks put in (tests).
    private(set) var chunks = 0
    /// Every row of the transcript is shown (the open's window has grown to all of it).
    var filled: Bool { list.source.window?.complete ?? true }

    #if DEBUG
    /// Off: the window grows only by `growOnce` (tests that time each growth, or that put one in
    /// with landed rows pending). Rows that land wait for the next `growOnce` until every row is in.
    var growsByItself = true

    /// Each chunk: the display frame it went in on, and the main thread's time it took.
    struct ChunkRecord {
        var frame: Int
        var timestamp: CFTimeInterval
        var ms: Double
    }
    private(set) var chunkLog: [ChunkRecord] = []

    /// One chunk in, now (tests). False once every row is shown (rows landed and still pending
    /// are reloaded then).
    @discardableResult
    func growOnce() -> Bool {
        guard let window = list.source.window, window.grow() else {
            if list.hasPendingLandings { list.reload() }
            return false
        }
        chunks += 1
        list.sourceRowsChanged()
        return true
    }
    #endif

    /// Whether rows that land wait for the next chunk (the fill runs, so one comes next frame).
    private var defersLandings: Bool {
        #if DEBUG
        if !growsByItself { return !filled }
        #endif
        return link != nil
    }

    private func fill() {
        #if DEBUG
        guard growsByItself else { return }
        #endif
        guard link == nil, let window = list.source.window, !window.complete else { return }
        let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A display frame of the fill: the next chunk, which takes in place the rows that landed since
    /// the last one. With every row in, the rows still pending are reloaded and the fill stops.
    fileprivate func fillFrame(_ link: CADisplayLink) {
        frames += 1
        guard let window = list.source.window, window.grow() else {
            stopFilling()
            if list.hasPendingLandings { list.reload() }
            return
        }
        chunks += 1
        #if DEBUG
        let start = ContinuousClock.now
        #endif
        list.sourceRowsChanged()
        #if DEBUG
        let spent = start.duration(to: .now)
        chunkLog.append(ChunkRecord(frame: frames, timestamp: link.timestamp,
                                    ms: Double(spent.components.seconds) * 1000 + Double(spent.components.attoseconds) / 1e15))
        #endif
    }

    private func stopFilling() {
        link?.invalidate()
        link = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Off screen the fill stops: what landed is reloaded, the rest come when it shows again.
        guard link != nil else { return }
        stopFilling()
        if list.hasPendingLandings { list.reload() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if positioned { fill() }
    }

    // MARK: The reader's scroll decides whether the end is followed.

    /// The reader's finger takes the transcript: following stops this frame, so the end is never
    /// pulled back under a drag. Coming to rest within the end's band follows it again.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        follow.follows = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only a fling's coast: under the finger, following stays off (`scrollViewWillBeginDragging`).
        guard positioned, !scrollView.isTracking, scrollView.isDecelerating else { return }
        _ = follow.changed(atEnd: onEnd, grew: false, scrolling: true, running: running())
    }
}

/// SwiftUI wrapper for `SubagentTranscriptHost`.
struct SubagentTranscriptRepresentable: UIViewControllerRepresentable {
    let store: AgentChatStore
    let subagentID: String
    var probe: FollowProbe?
    /// A subagent row tapped in a nested-subagent card.
    let open: (String) -> Void

    func makeUIViewController(context: Context) -> SubagentTranscriptHost {
        let host = SubagentTranscriptHost(store: store, subagentID: subagentID, probe: probe)
        host.list.context.openSubagent = open
        return host
    }

    func updateUIViewController(_ host: SubagentTranscriptHost, context: Context) {
        host.list.context.openSubagent = open
    }
}

/// The display link's target: it holds the host weakly (a display link retains its target).
@MainActor
private final class FrameTarget: NSObject {
    weak var host: SubagentTranscriptHost?
    init(_ host: SubagentTranscriptHost) { self.host = host }
    @objc func frame(_ link: CADisplayLink) {
        guard let host else { link.invalidate(); return }
        host.fillFrame(link)
    }
}
#endif
