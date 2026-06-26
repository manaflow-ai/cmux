#if os(iOS)
import CmuxAgentChat
import SwiftUI
import UIKit

/// UIKit-backed transcript list used on iOS for deterministic keyboard and inset behavior.
struct ChatTranscriptTableView: UIViewRepresentable {
    let rows: [ChatTranscriptRow]
    let expandedIDs: Set<String>
    let agentState: ChatAgentState
    let hasMoreHistory: Bool
    let hasLoadedInitialHistory: Bool
    let initialLoadFailed: Bool
    let historyTruncatedAtHead: Bool
    let actions: ChatRowActions
    let onReachTop: () -> Void
    let onRetryInitialLoad: () -> Void
    @Binding var isAtBottom: Bool
    let scrollToBottomRequest: Int

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatMarkdownRenderer) private var markdownRenderer
    @Environment(\.chatContentCache) private var contentCache

    func makeCoordinator() -> Coordinator {
        Coordinator(isAtBottom: $isAtBottom)
    }

    func makeUIView(context: Context) -> ChatTranscriptUITableView {
        let tableView = ChatTranscriptUITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.estimatedRowHeight = 96
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.attach(tableView)
        return tableView
    }

    func updateUIView(_ tableView: ChatTranscriptUITableView, context: Context) {
        context.coordinator.update(
            configuration: ChatTranscriptTableConfiguration(
                rows: rows,
                expandedIDs: expandedIDs,
                agentState: agentState,
                hasMoreHistory: hasMoreHistory,
                hasLoadedInitialHistory: hasLoadedInitialHistory,
                initialLoadFailed: initialLoadFailed,
                historyTruncatedAtHead: historyTruncatedAtHead,
                actions: actions,
                onReachTop: onReachTop,
                onRetryInitialLoad: onRetryInitialLoad,
                theme: theme,
                markdownRenderer: markdownRenderer,
                contentCache: contentCache
            ),
            in: tableView,
            scrollToBottomRequest: scrollToBottomRequest
        )
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        private var configuration: ChatTranscriptTableConfiguration?
        private var items: [ChatTranscriptTableItem] = []
        private var expandedIDs: Set<String> = []
        private var agentState: ChatAgentState = .idle
        private var topRequestKey: String?
        private var lastScrollToBottomRequest = 0
        private var isHandlingLayout = false
        private var shouldPreserveKeyboardViewport = false
        private var keyboardWasAtBottom = false
        private var keyboardVisibleBottomY: CGFloat?
        private var keyboardBottomAnchor: ChatTranscriptTableBottomAnchor?
        private var keyboardAnimationDuration: TimeInterval = 0
        private var keyboardAnimationOptions: UIView.AnimationOptions = []
        private weak var tableView: ChatTranscriptUITableView?
        private var isAtBottom: Binding<Bool>

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottom = isAtBottom
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillChangeFrame),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardDidChangeFrame),
                name: UIResponder.keyboardDidChangeFrameNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(_ tableView: ChatTranscriptUITableView) {
            self.tableView = tableView
            tableView.afterLayout = { [weak self, weak tableView] oldBoundsSize, oldContentSize in
                guard let self, let tableView else { return }
                self.handleLayoutChange(
                    in: tableView,
                    oldBoundsSize: oldBoundsSize,
                    oldContentSize: oldContentSize
                )
            }
        }

        fileprivate func update(
            configuration: ChatTranscriptTableConfiguration,
            in tableView: ChatTranscriptUITableView,
            scrollToBottomRequest: Int
        ) {
            self.configuration = configuration
            let nextItems = configuration.makeItems()
            let shouldReload = nextItems != items
                || configuration.expandedIDs != expandedIDs
                || configuration.agentState != agentState
            let shouldScrollToBottom = scrollToBottomRequest != lastScrollToBottomRequest
            lastScrollToBottomRequest = scrollToBottomRequest
            let wasAtBottom = isAtBottom.wrappedValue || distanceFromBottom(in: tableView) <= Self.atBottomThreshold
            let anchor = firstVisibleAnchor(in: tableView)

            guard shouldReload else {
                if shouldScrollToBottom {
                    scrollToBottom(in: tableView, animated: true)
                }
                updateBottomState(from: tableView)
                return
            }

            items = nextItems
            expandedIDs = configuration.expandedIDs
            agentState = configuration.agentState

            tableView.reloadData()
            tableView.layoutIfNeeded()

            if shouldScrollToBottom || wasAtBottom {
                scrollToBottom(in: tableView, animated: false)
            } else if let anchor {
                restore(anchor, in: tableView)
            }
            updateBottomState(from: tableView)
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            items.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "ChatTranscriptCell")
                ?? UITableViewCell(style: .default, reuseIdentifier: "ChatTranscriptCell")
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.selectionStyle = .none
            guard let configuration else { return cell }
            let item = items[indexPath.row]
            let tableWidth = ChatContainerWidth(tableView: tableView).effectiveWidth
            cell.contentConfiguration = UIHostingConfiguration {
                configuration.view(for: item, tableWidth: tableWidth)
            }
            .margins(.all, 0)
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            updateBottomState(from: tableView)
            requestOlderHistoryIfNeeded(in: tableView)
        }

        private func handleLayoutChange(
            in tableView: ChatTranscriptUITableView,
            oldBoundsSize: CGSize,
            oldContentSize: CGSize
        ) {
            guard !isHandlingLayout else { return }
            let boundsChanged = abs(oldBoundsSize.height - tableView.bounds.height) > 0.5
                || abs(oldBoundsSize.width - tableView.bounds.width) > 0.5
            let contentChanged = abs(oldContentSize.height - tableView.contentSize.height) > 0.5
            guard boundsChanged || contentChanged else {
                updateBottomState(from: tableView)
                return
            }

            isHandlingLayout = true
            defer { isHandlingLayout = false }

            if shouldPreserveKeyboardViewport {
                preserveViewportAfterLayout(in: tableView)
            } else if isAtBottom.wrappedValue {
                scrollToBottom(in: tableView, animated: false)
            }
            updateBottomState(from: tableView)
        }

        private func firstVisibleAnchor(in tableView: UITableView) -> ChatTranscriptTableAnchor? {
            guard let indexPath = tableView.indexPathsForVisibleRows?.min(),
                  items.indices.contains(indexPath.row)
            else { return nil }
            let item = items[indexPath.row]
            let rect = tableView.rectForRow(at: indexPath)
            return ChatTranscriptTableAnchor(
                id: item.id,
                offsetFromRowTop: tableView.contentOffset.y - rect.minY
            )
        }

        private func restore(_ anchor: ChatTranscriptTableAnchor, in tableView: UITableView) {
            guard let row = items.firstIndex(where: { $0.id == anchor.id }) else { return }
            let indexPath = IndexPath(row: row, section: 0)
            let rect = tableView.rectForRow(at: indexPath)
            let offset = CGPoint(
                x: tableView.contentOffset.x,
                y: clampedOffsetY(rect.minY + anchor.offsetFromRowTop, in: tableView)
            )
            tableView.setContentOffset(offset, animated: false)
        }

        private func bottomVisibleAnchor(in tableView: UITableView) -> ChatTranscriptTableBottomAnchor? {
            guard let indexPath = tableView.indexPathsForVisibleRows?.max(),
                  items.indices.contains(indexPath.row)
            else { return nil }
            let item = items[indexPath.row]
            let rect = tableView.rectForRow(at: indexPath)
            let visibleBottom = tableView.contentOffset.y
                + tableView.bounds.height
                - tableView.adjustedContentInset.bottom
            return ChatTranscriptTableBottomAnchor(
                id: item.id,
                offsetFromRowBottom: visibleBottom - rect.maxY
            )
        }

        private func restore(_ anchor: ChatTranscriptTableBottomAnchor, in tableView: UITableView) {
            guard let row = items.firstIndex(where: { $0.id == anchor.id }) else { return }
            let indexPath = IndexPath(row: row, section: 0)
            let rect = tableView.rectForRow(at: indexPath)
            let targetY = rect.maxY
                + anchor.offsetFromRowBottom
                - tableView.bounds.height
                + tableView.adjustedContentInset.bottom
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: clampedOffsetY(targetY, in: tableView)),
                animated: false
            )
        }

        private func preserveViewportAfterLayout(in tableView: UITableView) {
            let changes = {
                tableView.layoutIfNeeded()
                if self.keyboardWasAtBottom || self.isAtBottom.wrappedValue {
                    self.scrollToBottom(in: tableView, animated: false)
                } else if let keyboardVisibleBottomY = self.keyboardVisibleBottomY {
                    self.restoreVisibleBottom(keyboardVisibleBottomY, in: tableView)
                } else if let keyboardBottomAnchor = self.keyboardBottomAnchor {
                    self.restore(keyboardBottomAnchor, in: tableView)
                }
            }
            if keyboardAnimationDuration > 0 {
                UIView.animate(
                    withDuration: keyboardAnimationDuration,
                    delay: 0,
                    options: keyboardAnimationOptions.union([.beginFromCurrentState, .allowUserInteraction]),
                    animations: changes
                )
            } else {
                changes()
            }
        }

        private func scrollToBottom(in tableView: UITableView, animated: Bool) {
            tableView.layoutIfNeeded()
            let targetY = maxOffsetY(in: tableView)
            tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: targetY), animated: animated)
            setAtBottom(true)
        }

        private func requestOlderHistoryIfNeeded(in tableView: UITableView) {
            guard let configuration, configuration.hasMoreHistory else {
                topRequestKey = nil
                return
            }
            let visibleTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
            guard visibleTop <= 80 else { return }
            let nextKey = "\(items.first?.id ?? "empty")#\(items.count)"
            guard topRequestKey != nextKey else { return }
            topRequestKey = nextKey
            configuration.onReachTop()
        }

        private func updateBottomState(from tableView: UITableView) {
            setAtBottom(distanceFromBottom(in: tableView) <= Self.atBottomThreshold)
        }

        private func setAtBottom(_ value: Bool) {
            if isAtBottom.wrappedValue != value {
                isAtBottom.wrappedValue = value
            }
        }

        private func distanceFromBottom(in tableView: UITableView) -> CGFloat {
            guard tableView.bounds.height > 0 else { return 0 }
            let visibleBottom = visibleBottomY(in: tableView)
            return max(0, tableView.contentSize.height - visibleBottom)
        }

        private func visibleBottomY(in tableView: UITableView) -> CGFloat {
            tableView.contentOffset.y
                + tableView.bounds.height
                - tableView.adjustedContentInset.bottom
        }

        private func restoreVisibleBottom(_ visibleBottomY: CGFloat, in tableView: UITableView) {
            let targetY = visibleBottomY
                - tableView.bounds.height
                + tableView.adjustedContentInset.bottom
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: clampedOffsetY(targetY, in: tableView)),
                animated: false
            )
        }

        private func maxOffsetY(in tableView: UITableView) -> CGFloat {
            max(
                -tableView.adjustedContentInset.top,
                tableView.contentSize.height
                    - tableView.bounds.height
                    + tableView.adjustedContentInset.bottom
            )
        }

        private func clampedOffsetY(_ offsetY: CGFloat, in tableView: UITableView) -> CGFloat {
            min(max(offsetY, -tableView.adjustedContentInset.top), maxOffsetY(in: tableView))
        }

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard let tableView else { return }
            keyboardWasAtBottom = isAtBottom.wrappedValue
                || distanceFromBottom(in: tableView) <= Self.atBottomThreshold
            keyboardVisibleBottomY = visibleBottomY(in: tableView)
            keyboardBottomAnchor = bottomVisibleAnchor(in: tableView)
            keyboardAnimationDuration = Self.keyboardAnimationDuration(from: notification)
            keyboardAnimationOptions = Self.keyboardAnimationOptions(from: notification)
            shouldPreserveKeyboardViewport = true
        }

        @objc private func keyboardDidChangeFrame(_ notification: Notification) {
            guard let tableView, shouldPreserveKeyboardViewport else { return }
            tableView.layoutIfNeeded()
            preserveViewportAfterLayout(in: tableView)
            shouldPreserveKeyboardViewport = false
            keyboardWasAtBottom = false
            keyboardVisibleBottomY = nil
            keyboardBottomAnchor = nil
            keyboardAnimationDuration = 0
            keyboardAnimationOptions = []
        }

        private static let atBottomThreshold: CGFloat = 40

        private static func keyboardAnimationDuration(from notification: Notification) -> TimeInterval {
            notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0
        }

        private static func keyboardAnimationOptions(from notification: Notification) -> UIView.AnimationOptions {
            guard let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int else {
                return []
            }
            return UIView.AnimationOptions(rawValue: UInt(curve << 16))
        }
    }
}

private struct ChatTranscriptTableConfiguration {
    let rows: [ChatTranscriptRow]
    let expandedIDs: Set<String>
    let agentState: ChatAgentState
    let hasMoreHistory: Bool
    let hasLoadedInitialHistory: Bool
    let initialLoadFailed: Bool
    let historyTruncatedAtHead: Bool
    let actions: ChatRowActions
    let onReachTop: () -> Void
    let onRetryInitialLoad: () -> Void
    let theme: ChatTheme
    let markdownRenderer: ChatMarkdownRenderer?
    let contentCache: ChatContentCache?

    func makeItems() -> [ChatTranscriptTableItem] {
        var items: [ChatTranscriptTableItem] = []
        if hasMoreHistory {
            items.append(.loadingMore)
        } else if historyTruncatedAtHead {
            items.append(.historyTruncated)
        }
        if rows.isEmpty {
            if initialLoadFailed {
                items.append(.loadFailed)
            } else if hasLoadedInitialHistory {
                items.append(.empty)
            } else {
                items.append(.initialLoading)
            }
        }
        items.append(contentsOf: rows.map(ChatTranscriptTableItem.row))
        if case .working = agentState {
            items.append(.typing)
        }
        items.append(.bottomAnchor)
        return items
    }

    @ViewBuilder
    func view(for item: ChatTranscriptTableItem, tableWidth: CGFloat) -> some View {
        itemView(for: item)
            .padding(.horizontal, theme.horizontalMargin)
            .environment(\.chatTheme, theme)
            .environment(\.chatMarkdownRenderer, markdownRenderer)
            .environment(\.chatContentCache, contentCache)
            .environment(
                \.chatBubbleMaxWidth,
                tableWidth > 0 ? tableWidth * theme.bubbleMaxWidthFraction : .infinity
            )
    }

    @ViewBuilder
    private func itemView(for item: ChatTranscriptTableItem) -> some View {
        switch item {
        case .loadingMore:
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 12)
        case .historyTruncated:
            Text(
                String(
                    localized: "chat.history.truncated",
                    defaultValue: "Earlier history is on your Mac",
                    bundle: .module
                )
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 12)
        case .loadFailed:
            VStack(spacing: 12) {
                Text(
                    String(
                        localized: "chat.transcript.load_failed",
                        defaultValue: "Couldn't load this conversation",
                        bundle: .module
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Button(action: onRetryInitialLoad) {
                    Text(
                        String(localized: "chat.transcript.retry", defaultValue: "Retry", bundle: .module)
                    )
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ChatTranscriptRetry")
            }
            .padding(.vertical, 48)
        case .empty:
            Text(
                String(
                    localized: "chat.transcript.empty",
                    defaultValue: "No messages yet",
                    bundle: .module
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 48)
        case .initialLoading:
            ProgressView()
                .controlSize(.regular)
                .padding(.vertical, 48)
        case .row(let row):
            ChatTranscriptRowView(
                row: row,
                isExpanded: expandedIDs.contains(row.id),
                actions: actions
            )
            .equatable()
        case .typing:
            ChatTypingIndicatorView(agentState: agentState)
                .padding(.top, theme.intraGroupSpacing)
        case .bottomAnchor:
            Color.clear
                .frame(height: 9)
        }
    }
}

private enum ChatTranscriptTableItem: Equatable {
    case loadingMore
    case historyTruncated
    case loadFailed
    case empty
    case initialLoading
    case row(ChatTranscriptRow)
    case typing
    case bottomAnchor

    var id: String {
        switch self {
        case .loadingMore:
            return "loading-more"
        case .historyTruncated:
            return "history-truncated"
        case .loadFailed:
            return "load-failed"
        case .empty:
            return "empty"
        case .initialLoading:
            return "initial-loading"
        case .row(let row):
            return row.id
        case .typing:
            return "typing"
        case .bottomAnchor:
            return "bottom-anchor"
        }
    }
}

private struct ChatTranscriptTableAnchor {
    let id: String
    let offsetFromRowTop: CGFloat
}

private struct ChatTranscriptTableBottomAnchor {
    let id: String
    let offsetFromRowBottom: CGFloat
}

final class ChatTranscriptUITableView: UITableView {
    var afterLayout: ((_ oldBoundsSize: CGSize, _ oldContentSize: CGSize) -> Void)?
    private var lastBoundsSize: CGSize = .zero
    private var lastContentSize: CGSize = .zero

    override func layoutSubviews() {
        let oldBoundsSize = lastBoundsSize
        let oldContentSize = lastContentSize
        super.layoutSubviews()
        lastBoundsSize = bounds.size
        lastContentSize = contentSize
        afterLayout?(oldBoundsSize, oldContentSize)
    }
}
#endif
