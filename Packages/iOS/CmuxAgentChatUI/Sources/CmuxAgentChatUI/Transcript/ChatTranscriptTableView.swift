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
        private var isExplicitBottomFollowActive = false
        private var isUserVisibleBottomFollowActive = false
        private var needsInitialUserVisibleBottomStaging = false
        private var isUserVisibleBottomAnimationRunning = false
        private var lastObservedScrollContentHeight: CGFloat?
        private var lastObservedScrollOffsetY: CGFloat?
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
            if shouldScrollToBottom {
                isExplicitBottomFollowActive = true
                isUserVisibleBottomFollowActive = true
                needsInitialUserVisibleBottomStaging = true
                isUserVisibleBottomAnimationRunning = false
                syncDebugBottomFollowState(in: tableView)
                recordObservedScrollPosition(in: tableView)
            }
            let wasAtBottom = distanceFromBottom(in: tableView) <= chatTranscriptAtBottomThreshold
            let anchor = firstVisibleAnchor(in: tableView)

            guard shouldReload else {
                if isExplicitBottomFollowActive && (shouldScrollToBottom || !wasAtBottom) {
                    pendingContentUpdateAnchor = nil
                    if shouldScrollToBottom {
                        scrollToBottomForUserVisibleFollow(in: tableView)
                    } else {
                        scrollToBottomForFollow(in: tableView)
                    }
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
            if isExplicitBottomFollowActive || (wasAtBottom && !tableView.isUserScrollMomentumActive) {
                pendingContentUpdateAnchor = nil
                if shouldScrollToBottom {
                    scrollToBottomForUserVisibleFollow(in: tableView)
                } else {
                    scrollToBottomForFollow(in: tableView)
                }
            } else if let anchor, !tableView.isUserScrollMomentumActive {
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
            cancelBottomFollowForStableContentUpwardScroll(in: tableView)
            updateBottomState(from: tableView)
            recordObservedScrollPosition(in: tableView)
            #if DEBUG
            (tableView as? ChatTranscriptUITableView)?.updateDebugAccessibilityValue()
            #endif
            requestOlderHistoryIfNeeded(in: tableView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            pendingContentUpdateAnchor = nil
            isExplicitBottomFollowActive = false
            isUserVisibleBottomFollowActive = false
            needsInitialUserVisibleBottomStaging = false
            isUserVisibleBottomAnimationRunning = false
            syncDebugBottomFollowState(in: scrollView as? UITableView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            isUserVisibleBottomAnimationRunning = false
            if isExplicitBottomFollowActive,
               distanceFromBottom(in: tableView) > chatTranscriptAtBottomThreshold {
                scrollToBottomForFollow(in: tableView)
            } else {
                isUserVisibleBottomFollowActive = false
                needsInitialUserVisibleBottomStaging = false
                updateBottomState(from: tableView)
            }
            syncDebugBottomFollowState(in: tableView)
        }

        private func cancelBottomFollowForStableContentUpwardScroll(in tableView: UITableView) {
            // Streaming content growth can increase distance from bottom; stable-content upward offsets mean scrolling took over.
            guard isExplicitBottomFollowActive,
                  !isHandlingLayout,
                  !isApplyingDataUpdate,
                  let lastObservedScrollContentHeight,
                  let lastObservedScrollOffsetY,
                  abs(tableView.contentSize.height - lastObservedScrollContentHeight) <= 0.5,
                  tableView.contentOffset.y < lastObservedScrollOffsetY - 1
            else {
                return
            }
            isExplicitBottomFollowActive = false
            isUserVisibleBottomFollowActive = false
            needsInitialUserVisibleBottomStaging = false
            isUserVisibleBottomAnimationRunning = false
            syncDebugBottomFollowState(in: tableView)
        }

        private func recordObservedScrollPosition(in tableView: UITableView) {
            lastObservedScrollContentHeight = tableView.contentSize.height
            lastObservedScrollOffsetY = tableView.contentOffset.y
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

            if tableView.isUserScrollMomentumActive {
                if isExplicitBottomFollowActive {
                    scrollToBottomForFollow(in: tableView)
                }
                pendingContentUpdateAnchor = nil
                updateBottomState(from: tableView)
                return
            }
            if tableView.isViewportInsetsExternallyDriven || isApplyingDataUpdate {
                if isExplicitBottomFollowActive {
                    scrollToBottomForFollow(in: tableView)
                    return
                }
                updateBottomState(from: tableView)
                return
            }

            if isExplicitBottomFollowActive {
                scrollToBottomForFollow(in: tableView)
            } else if boundsChanged, let oldViewport {
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

        private func scrollToBottomForUserVisibleFollow(in tableView: UITableView) {
            tableView.layoutIfNeeded()
            cancelUserScrollMomentumIfNeeded(in: tableView)
            let targetY = maxOffsetY(in: tableView)
            let distance = max(0, targetY - tableView.contentOffset.y)
            guard distance > chatTranscriptAtBottomThreshold else {
                guard !isUserVisibleBottomAnimationRunning else {
                    (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
                    updateBottomState(from: tableView)
                    return
                }
                isUserVisibleBottomFollowActive = false
                needsInitialUserVisibleBottomStaging = false
                scrollToBottom(in: tableView, animated: false)
                return
            }

            let visibleDistance = userVisibleFinalGlideDistance(in: tableView)
            if needsInitialUserVisibleBottomStaging, distance > visibleDistance {
                let stagedOffsetY = clampedOffsetY(targetY - visibleDistance, in: tableView)
                tableView.setContentOffset(
                    CGPoint(x: tableView.contentOffset.x, y: stagedOffsetY),
                    animated: false
                )
                #if DEBUG
                (tableView as? ChatTranscriptUITableView)?.recordBottomUserVisibleStaging()
                #endif
                (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
                updateBottomState(from: tableView)
            }
            needsInitialUserVisibleBottomStaging = false

            isUserVisibleBottomAnimationRunning = true
            syncDebugBottomFollowState(in: tableView)
            if scrollToBottom(in: tableView, animated: true) {
                #if DEBUG
                (tableView as? ChatTranscriptUITableView)?.recordBottomScrollRequest(
                    animated: true,
                    userVisible: true
                )
                #endif
            } else {
                isUserVisibleBottomAnimationRunning = false
                updateBottomState(from: tableView)
            }
        }

        private func scrollToBottomForFollow(in tableView: UITableView) {
            if isUserVisibleBottomFollowActive {
                scrollToBottomForUserVisibleFollow(in: tableView)
                return
            }
            if scrollToBottom(in: tableView, animated: false) {
                #if DEBUG
                (tableView as? ChatTranscriptUITableView)?.recordBottomScrollRequest(
                    animated: false,
                    userVisible: false
                )
                #endif
            }
        }

        @discardableResult
        private func scrollToBottom(in tableView: UITableView, animated: Bool) -> Bool {
            tableView.layoutIfNeeded()
            cancelUserScrollMomentumIfNeeded(in: tableView)
            let targetY = maxOffsetY(in: tableView)
            guard abs(tableView.contentOffset.y - targetY) > 0.5 else {
                (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
                updateBottomState(from: tableView)
                return false
            }
            tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: targetY), animated: animated)
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
            updateBottomState(from: tableView)
            return true
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
            let isBottom = distanceFromBottom(in: tableView) <= chatTranscriptAtBottomThreshold
            setAtBottom(isBottom)
            if isBottom, !isUserVisibleBottomAnimationRunning {
                isUserVisibleBottomFollowActive = false
                needsInitialUserVisibleBottomStaging = false
            }
            syncDebugBottomFollowState(in: tableView)
        }

        private func syncDebugBottomFollowState(in tableView: UITableView?) {
            #if DEBUG
            (tableView as? ChatTranscriptUITableView)?.recordBottomUserVisibleFollow(
                active: isUserVisibleBottomFollowActive,
                animationRunning: isUserVisibleBottomAnimationRunning
            )
            #endif
        }

        private func setAtBottom(_ value: Bool) {
            if isAtBottom.wrappedValue != value {
                isAtBottom.wrappedValue = value
            }
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

#endif
