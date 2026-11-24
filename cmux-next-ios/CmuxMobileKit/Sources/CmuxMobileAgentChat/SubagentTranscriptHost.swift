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

    init(store: AgentChatStore, subagentID: String, probe: FollowProbe? = nil) {
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
        source.window?.enabled = true
        super.init(nibName: nil, bundle: nil)
        list.scrollDelegate = self
        // A finished transcript opens at its top: its newest rows are not primed on the main thread.
        list.opensOnNewest = { [weak self] in self?.follow.follows ?? true }
        // A row above the reader that changes height moves nothing they see, unless the end of a
        // running subagent is followed (then the end stays in place).
        list.layout.followsBottom = { [weak self] in
            guard let self else { return false }
            return self.follow.sizeChangeAnchor(running: self.running()) == .bottom
        }
        list.collectionView.didLayout = { [weak self] in self?.laidOut() }
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

    /// Chunks of the transcript's rows a frame each until every row is shown: below a finished
    /// one's top, above a running one's end (the list keeps the reader's rows where they are).
    private var filling: Task<Void, Never>?
    /// Chunks put in (tests).
    private(set) var chunks = 0
    /// Every row of the transcript is shown (the open's window has grown to all of it).
    var filled: Bool { list.source.window?.complete ?? true }

    private func fill() {
        guard filling == nil, let window = list.source.window, !window.complete else { return }
        filling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await Self.nextFrame()
                guard let self, let window = self.list.source.window, window.grow() else { break }
                self.chunks += 1
                self.list.sourceRowsChanged()
            }
            self?.filling = nil
        }
    }

    private static func nextFrame() async {
        try? await Task.sleep(for: .milliseconds(16))
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
#endif
