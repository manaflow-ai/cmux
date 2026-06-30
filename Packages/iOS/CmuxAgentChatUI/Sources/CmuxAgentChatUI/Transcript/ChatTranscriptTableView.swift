#if os(iOS)
import CmuxAgentChat
import CmuxMobileSupport
import Foundation
import SwiftUI
import UIKit

let chatTranscriptAtBottomThreshold: CGFloat = 40

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
        if #available(iOS 26.0, *) {
            tableView.contentInsetAdjustmentBehavior = .automatic
        } else {
            tableView.contentInsetAdjustmentBehavior = .never
        }
        tableView.estimatedRowHeight = 96
        tableView.rowHeight = UITableView.automaticDimension
        tableView.allowsSelection = false
        tableView.accessibilityIdentifier = "ChatTranscriptTableView"
        tableView.applyScrollEdgeEffects(topSoft: true, bottomSoft: true)
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
        private var isApplyingDataUpdate = false
        private var pendingContentUpdateAnchor: ChatTranscriptTableAnchor?
        private weak var tableView: ChatTranscriptUITableView?
        private var isAtBottom: Binding<Bool>
        #if DEBUG
        private var didApplyDebugInitialScroll = false
        #endif

        init(isAtBottom: Binding<Bool>) {
            self.isAtBottom = isAtBottom
            super.init()
        }

        func attach(_ tableView: ChatTranscriptUITableView) {
            self.tableView = tableView
            tableView.anchorBeforeLayout = { [weak self, weak tableView] in
                guard let self, let tableView else { return nil }
                return self.firstVisibleAnchor(in: tableView)
            }
            tableView.afterLayout = { [weak self, weak tableView] oldBoundsSize, oldContentSize, oldViewport, oldAnchor in
                guard let self, let tableView else { return }
                self.handleLayoutChange(
                    in: tableView,
                    oldBoundsSize: oldBoundsSize,
                    oldContentSize: oldContentSize,
                    oldViewport: oldViewport,
                    oldAnchor: oldAnchor
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
            let wasAtBottom = distanceFromBottom(in: tableView) <= chatTranscriptAtBottomThreshold
            let anchor = firstVisibleAnchor(in: tableView)

            guard shouldReload else {
                if shouldScrollToBottom {
                    pendingContentUpdateAnchor = nil
                    scrollToBottom(in: tableView, animated: true)
                }
                updateBottomState(from: tableView)
                return
            }

            pendingContentUpdateAnchor = nil
            items = nextItems
            expandedIDs = configuration.expandedIDs
            agentState = configuration.agentState

            isApplyingDataUpdate = true
            defer { isApplyingDataUpdate = false }
            tableView.reloadData()
            tableView.layoutIfNeeded()

            let isUserScrollMomentumActive = tableView.isUserScrollMomentumActive
            if shouldScrollToBottom || (wasAtBottom && !isUserScrollMomentumActive) {
                pendingContentUpdateAnchor = nil
                scrollToBottom(in: tableView, animated: false)
            } else if !isUserScrollMomentumActive, let anchor {
                restore(anchor, in: tableView)
                pendingContentUpdateAnchor = anchor
            }
            #if DEBUG
            applyDebugInitialScrollIfNeeded(in: tableView)
            #endif
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
            #if DEBUG
            (tableView as? ChatTranscriptUITableView)?.updateDebugAccessibilityValue()
            #endif
            requestOlderHistoryIfNeeded(in: tableView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pendingContentUpdateAnchor = nil
        }

        private func handleLayoutChange(
            in tableView: ChatTranscriptUITableView,
            oldBoundsSize: CGSize,
            oldContentSize: CGSize,
            oldViewport: MobileScrollViewportSnapshot?,
            oldAnchor: ChatTranscriptTableAnchor?
        ) {
            guard !isHandlingLayout else { return }
            let boundsChanged = abs(oldBoundsSize.height - tableView.bounds.height) > 0.5
                || abs(oldBoundsSize.width - tableView.bounds.width) > 0.5
            let contentChanged = abs(oldContentSize.height - tableView.contentSize.height) > 0.5
            guard boundsChanged || contentChanged else {
                if !isApplyingDataUpdate {
                    pendingContentUpdateAnchor = nil
                }
                updateBottomState(from: tableView)
                return
            }

            isHandlingLayout = true
            defer { isHandlingLayout = false }

            if tableView.isViewportInsetsExternallyDriven {
                updateBottomState(from: tableView)
                return
            }
            if isApplyingDataUpdate {
                updateBottomState(from: tableView)
                return
            }
            if tableView.isUserScrollMomentumActive {
                pendingContentUpdateAnchor = nil
                updateBottomState(from: tableView)
                return
            }

            if boundsChanged, let oldViewport {
                restoreKeyboardViewport(snapshot: oldViewport, in: tableView)
            } else if contentChanged, let pendingContentUpdateAnchor {
                restore(pendingContentUpdateAnchor, in: tableView)
                self.pendingContentUpdateAnchor = nil
            } else if oldViewport?.wasAtBottom == true {
                scrollToBottom(in: tableView, animated: false)
            } else if contentChanged, let oldAnchor {
                restore(oldAnchor, in: tableView)
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
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
        }

        private func scrollToBottom(in tableView: UITableView, animated: Bool) {
            tableView.layoutIfNeeded()
            let targetY = maxOffsetY(in: tableView)
            tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: targetY), animated: animated)
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
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
            setAtBottom(distanceFromBottom(in: tableView) <= chatTranscriptAtBottomThreshold)
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

        #if DEBUG
        private func applyDebugInitialScrollIfNeeded(in tableView: UITableView) {
            guard !didApplyDebugInitialScroll,
                  ProcessInfo.processInfo.environment["CMUX_UITEST_CHAT_INITIAL_SCROLL"] == "middle",
                  tableView.bounds.height > 0,
                  tableView.contentSize.height > tableView.bounds.height * 1.4
            else {
                return
            }
            didApplyDebugInitialScroll = true
            let minY = -tableView.adjustedContentInset.top
            let maxY = maxOffsetY(in: tableView)
            let targetY = clampedOffsetY(minY + ((maxY - minY) * 0.5), in: tableView)
            tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: targetY), animated: false)
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
            setAtBottom(false)
        }
        #endif

        private func restoreKeyboardViewport(
            snapshot: MobileScrollViewportSnapshot,
            in tableView: UITableView
        ) {
            let offsetY = snapshot.restoredOffsetY(
                contentHeight: tableView.contentSize.height,
                boundsHeight: tableView.bounds.height,
                adjustedTopInset: tableView.adjustedContentInset.top,
                adjustedBottomInset: tableView.adjustedContentInset.bottom
            )
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: offsetY),
                animated: false
            )
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
            setAtBottom(snapshot.wasAtBottom)
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

#endif
