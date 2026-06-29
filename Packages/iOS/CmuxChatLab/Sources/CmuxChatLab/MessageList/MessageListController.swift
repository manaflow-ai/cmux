#if canImport(UIKit)
import CmuxAgentChat
import Nuke
import Observation
import UIKit

/// The inverted message list. A plain `UIViewController` (never
/// `UICollectionViewController`, which auto-mangles insets) hosting a
/// `UICollectionView` flipped on the Y axis so item 0 is the visual bottom:
/// "pinned to bottom" is free and prepending older history is an append with no
/// visible jump. Driven by a diffable data source keyed on stable row ids.
@MainActor
final class MessageListController: UIViewController {
    let collectionView: UICollectionView
    private let store: ChatConversationStore
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rowsByID: [String: ChatTranscriptRow] = [:]
    private let prefetcher = ImagePrefetcher()

    /// Called when the user scrolls; lets the owner drive keyboard-synced
    /// inset math off the same signals.
    var onScroll: ((UIScrollView) -> Void)?
    var onBeginDragging: ((UIScrollView) -> Void)?
    var onEndDragging: ((UIScrollView) -> Void)?

    init(store: ChatConversationStore) {
        self.store = store
        let layout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = false
            config.backgroundColor = .clear
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        collectionView.backgroundColor = .systemBackground
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.accessibilityIdentifier = "ChatLabList"
        collectionView.register(BubbleCell.self, forCellWithReuseIdentifier: BubbleCell.reuseID)
        collectionView.register(ImageBubbleCell.self, forCellWithReuseIdentifier: ImageBubbleCell.reuseID)
        collectionView.register(StatusCell.self, forCellWithReuseIdentifier: StatusCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        configureDataSource()
        observeRows()
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            guard let self, let row = rowsByID[id] else {
                return collectionView.dequeueReusableCell(withReuseIdentifier: StatusCell.reuseID, for: indexPath)
            }
            return cell(for: row, at: indexPath, in: collectionView)
        }
    }

    private func cell(for row: ChatTranscriptRow, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        switch row {
        case .message(let snapshot):
            return messageCell(snapshot.message, at: indexPath, in: collectionView, pending: false)
        case .pendingOutbound(let pending):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BubbleCell.reuseID, for: indexPath) as! BubbleCell
            cell.configure(text: pending.text, side: .mine, pending: true)
            return cell
        case .dateHeader(let day):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StatusCell.reuseID, for: indexPath) as! StatusCell
            cell.configure(text: Self.dayFormatter.string(from: day))
            return cell
        case .unreadSeparator:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StatusCell.reuseID, for: indexPath) as! StatusCell
            cell.configure(text: "Unread")
            return cell
        case .terminalCommand(let block):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BubbleCell.reuseID, for: indexPath) as! BubbleCell
            cell.configure(text: block.command, side: .theirs, pending: false)
            return cell
        }
    }

    private func messageCell(_ message: ChatMessage, at indexPath: IndexPath, in collectionView: UICollectionView, pending: Bool) -> UICollectionViewCell {
        let side: BubbleSide = message.role == .user ? .mine : .theirs
        switch message.kind {
        case .prose(let prose):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BubbleCell.reuseID, for: indexPath) as! BubbleCell
            cell.configure(text: prose.text, side: side, pending: pending)
            return cell
        case .attachment(let attachment):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ImageBubbleCell.reuseID, for: indexPath) as! ImageBubbleCell
            cell.configure(url: ChatLabMediaProvider.url(for: attachment), side: side)
            return cell
        case .status(let status):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StatusCell.reuseID, for: indexPath) as! StatusCell
            cell.configure(text: Self.statusText(status))
            return cell
        default:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: BubbleCell.reuseID, for: indexPath) as! BubbleCell
            cell.configure(text: Self.fallbackText(message.kind), side: side, pending: pending)
            return cell
        }
    }

    // MARK: - Observation

    /// Re-reads `store.rows` inside an observation transaction and re-applies
    /// the snapshot whenever it changes, then re-arms. This is the clean way to
    /// bridge an `@Observable` store into UIKit without an `ObservableObject`.
    private func observeRows() {
        // Read the tracked value inside the transaction and apply OUTSIDE it, so
        // the (heavy) snapshot apply doesn't pull unrelated observable reads into
        // the tracking set and re-fire spuriously.
        let rows = withObservationTracking {
            store.rows
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeRows() }
        }
        applySnapshot(rows: rows)
    }

    private func applySnapshot(rows: [ChatTranscriptRow]) {
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        // Inverted list: newest first so index 0 sits at the visual bottom.
        snapshot.appendItems(rows.reversed().map(\.id), toSection: 0)
        // Never animate: a prepended history page would otherwise animate in
        // mid-scroll and visibly jump. New-message insert polish is a separate,
        // targeted path (deferred), not blanket diff animation.
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func statusText(_ status: ChatStatusTransition) -> String {
        switch status.event {
        case .sessionStarted: return "Session started"
        case .sessionEnded: return "Session ended"
        case .interrupted: return "Interrupted"
        case .contextCompacted: return "Context compacted"
        }
    }

    private static func fallbackText(_ kind: ChatMessageKind) -> String {
        switch kind {
        case .thought: return "(thinking)"
        case .toolUse: return "(tool use)"
        case .terminal: return "(terminal output)"
        case .fileEdit: return "(file edit)"
        case .permissionRequest: return "(permission request)"
        case .question: return "(question)"
        case .unsupported: return "(unsupported)"
        default: return ""
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

extension MessageListController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // The last item in the (reversed) data source is the oldest row.
        let count = dataSource.snapshot().numberOfItems
        if indexPath.item >= count - 2 {
            Task { await store.loadOlder() }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScroll?(scrollView) }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onBeginDragging?(scrollView) }
    // Finger lifted: fire ALWAYS, regardless of `willDecelerate`. The touch ends
    // here whether or not momentum follows; the keyboard's interactive-dismiss
    // commit happens at lift, not at scroll-momentum end. Gating on `!decelerate`
    // (and using `didEndDecelerating` as the lift signal) tied keyboard-settle to
    // scroll momentum, which delayed the release on a fling.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onEndDragging?(scrollView)
    }
}

extension MessageListController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let urls = indexPaths.compactMap { indexPath -> URL? in
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  case let .message(snapshot) = rowsByID[id],
                  case let .attachment(attachment) = snapshot.message.kind
            else { return nil }
            return ChatLabMediaProvider.url(for: attachment)
        }
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }
}
#endif
