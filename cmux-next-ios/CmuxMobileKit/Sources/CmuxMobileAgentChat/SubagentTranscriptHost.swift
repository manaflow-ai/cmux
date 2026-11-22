#if os(iOS)
import SwiftUI
import UIKit

/// A subagent's transcript on the chat's transcript list (`ChatTranscriptList`, a collection view
/// of measured rows): the reader's place holds while rows above them change height, which a
/// SwiftUI lazy stack did not do (it reset the transcript to its top, and a 15,000 pt answer
/// stalled its layout). This host does only what the chat's controller does that a subagent
/// screen needs, without its composer and keyboard: where the transcript opens, and following
/// its end while the subagent runs. Holding the reader stays in the list's layout.
@MainActor
final class SubagentTranscriptHost: UIViewController, UIScrollViewDelegate {
    let list: ChatTranscriptList
    private let surface: AgentChatSurface
    private let running: () -> Bool
    /// The first layout with rows placed the transcript (its top, or its end while running).
    private(set) var positioned = false
    /// Within this of the end counts as on it (a fling that stops just short while a row lands).
    static let endBand: CGFloat = 60

    init(store: AgentChatStore, subagentID: String, surface: AgentChatSurface) {
        self.surface = surface
        let source = ChatTranscriptSource.subagent(subagentID, store: store)
        running = { source.runningTurn() != nil }
        list = ChatTranscriptList(store: store, surface: surface, source: source)
        list.foldsWork = false
        // Open on the end of a running subagent (following it), on the top of a finished one.
        surface.following = running()
        super.init(nibName: nil, bundle: nil)
        list.scrollDelegate = self
        // Rows above a reader change height without moving them unless the end is followed.
        list.layout.followsBottom = { [weak self] in self?.follows ?? false }
        list.collectionView.didLayout = { [weak self] in self?.laidOut() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The end is kept in view: the reader is on it and the subagent runs.
    var follows: Bool { surface.following && running() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let collectionView = list.collectionView
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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

    /// After each layout pass of the list: the opening place once, then the end while following.
    private func laidOut() {
        let scrollView = list.collectionView
        guard scrollView.bounds.height > 0, scrollView.contentSize.height > 0, !scrollView.isTracking else { return }
        if !positioned {
            positioned = true
            scrollView.contentOffset.y = surface.following ? bottomOffset : topOffset
        } else if follows, !scrollView.isDecelerating, abs(scrollView.contentOffset.y - bottomOffset) > 0.5 {
            scrollView.contentOffset.y = bottomOffset
        }
    }

    // MARK: The reader's scroll decides whether the end is followed.

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard positioned, scrollView.isTracking || scrollView.isDecelerating else { return }
        let onEnd = scrollView.contentOffset.y >= bottomOffset - Self.endBand
        if surface.following != onEnd { surface.following = onEnd }
    }
}

/// SwiftUI wrapper for `SubagentTranscriptHost`.
struct SubagentTranscriptRepresentable: UIViewControllerRepresentable {
    let store: AgentChatStore
    let subagentID: String
    let surface: AgentChatSurface
    /// A subagent row tapped in a nested-subagent card.
    let open: (String) -> Void

    func makeUIViewController(context: Context) -> SubagentTranscriptHost {
        let host = SubagentTranscriptHost(store: store, subagentID: subagentID, surface: surface)
        host.list.context.openSubagent = open
        return host
    }

    func updateUIViewController(_ host: SubagentTranscriptHost, context: Context) {
        host.list.context.openSubagent = open
    }
}
#endif
