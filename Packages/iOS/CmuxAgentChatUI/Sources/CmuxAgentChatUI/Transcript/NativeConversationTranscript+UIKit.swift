#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

struct NativeConversationTableRepresentable<Row, RowContent>: UIViewRepresentable
where Row: Identifiable & Equatable, Row.ID: Hashable & Sendable, RowContent: View {
    let rows: [Row]
    let hasMoreBefore: Bool
    let hasMoreAfter: Bool
    let followState: Binding<ConversationFollowState<Row.ID>>
    let command: ConversationScrollCommand?
    let renderGeneration: Int
    let isActive: Bool
    let beforePageID: String?
    let afterPageID: String?
    let prefetchResetGeneration: Int
    let onLoadBefore: () -> Void
    let onLoadAfter: () -> Void
    let onSemanticHead: () -> Void
    let onSemanticTail: () -> Void
    let rowContent: (Row) -> RowContent

    func makeCoordinator() -> Coordinator {
        Coordinator(followState: followState)
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
        tableView.accessibilityIdentifier = "NativeConversationTranscript"
        tableView.delegate = context.coordinator
        context.coordinator.attach(to: tableView)
        return tableView
    }

    func updateUIView(_ tableView: ChatTranscriptUITableView, context: Context) {
        context.coordinator.update(
            rows: rows,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            command: command,
            renderGeneration: renderGeneration,
            isActive: isActive,
            beforePageID: beforePageID,
            afterPageID: afterPageID,
            prefetchResetGeneration: prefetchResetGeneration,
            onLoadBefore: onLoadBefore,
            onLoadAfter: onLoadAfter,
            onSemanticHead: onSemanticHead,
            onSemanticTail: onSemanticTail,
            rowContent: rowContent,
            in: tableView
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate {
        private var rowsByID: [Row.ID: Row] = [:]
        private var orderedIDs: [Row.ID] = []
        private var dataSource: UITableViewDiffableDataSource<Int, Row.ID>?
        private var rowContent: ((Row) -> RowContent)?
        private var followState: Binding<ConversationFollowState<Row.ID>>
        private var hasMoreBefore = false
        private var hasMoreAfter = false
        private var onLoadBefore: () -> Void = {}
        private var onLoadAfter: () -> Void = {}
        private var onSemanticHead: () -> Void = {}
        private var onSemanticTail: () -> Void = {}
        private var lastCommandGeneration: Int?
        private var pendingSemanticCommandGeneration: Int?
        private var prefetchGate = ConversationPrefetchGate<ConversationPrefetchBoundary<Row.ID>>()
        private var beforePageID: String?
        private var afterPageID: String?
        private var prefetchResetGeneration = 0
        private var isApplyingUpdate = false
        private var isHandlingLayout = false
        private var pendingContentUpdateAnchor: Anchor?
        private var pendingUpdate: (() -> Void)?
        private var lastRenderGeneration: Int?
        private var pendingSemanticScrollTarget: ConversationScrollTarget?

        init(followState: Binding<ConversationFollowState<Row.ID>>) {
            self.followState = followState
        }

        func attach(to tableView: ChatTranscriptUITableView) {
            dataSource = UITableViewDiffableDataSource<Int, Row.ID>(tableView: tableView) { [weak self] tableView, _, rowID in
                guard let self,
                      let row = self.rowsByID[rowID],
                      let rowContent = self.rowContent
                else { return nil }
                let cell = tableView.dequeueReusableCell(withIdentifier: "NativeConversationCell")
                    ?? UITableViewCell(style: .default, reuseIdentifier: "NativeConversationCell")
                cell.backgroundColor = .clear
                cell.contentView.backgroundColor = .clear
                cell.selectionStyle = .none
                cell.contentConfiguration = UIHostingConfiguration {
                    rowContent(row)
                }
                .margins(.all, 0)
                return cell
            }
            tableView.anchorBeforeLayout = { [weak self, weak tableView] in
                guard let self, let tableView, let anchor = self.firstVisibleAnchor(in: tableView) else { return nil }
                return ChatTranscriptTableAnchor(id: AnyHashable(anchor.id), offsetFromRowTop: anchor.offset)
            }
            tableView.afterLayout = { [weak self, weak tableView] oldBounds, oldContent, oldViewport, oldAnchor in
                guard let self, let tableView else { return }
                self.handleLayoutChange(
                    in: tableView,
                    oldBoundsSize: oldBounds,
                    oldContentSize: oldContent,
                    oldViewport: oldViewport,
                    oldAnchor: oldAnchor
                )
            }
        }

        func update(
            rows: [Row],
            hasMoreBefore: Bool,
            hasMoreAfter: Bool,
            command: ConversationScrollCommand?,
            renderGeneration: Int,
            isActive: Bool,
            beforePageID: String?,
            afterPageID: String?,
            prefetchResetGeneration: Int,
            onLoadBefore: @escaping () -> Void,
            onLoadAfter: @escaping () -> Void,
            onSemanticHead: @escaping () -> Void,
            onSemanticTail: @escaping () -> Void,
            rowContent: @escaping (Row) -> RowContent,
            in tableView: ChatTranscriptUITableView
        ) {
            if isApplyingUpdate {
                pendingUpdate = { [weak self, weak tableView] in
                    guard let self, let tableView else { return }
                    self.update(
                        rows: rows,
                        hasMoreBefore: hasMoreBefore,
                        hasMoreAfter: hasMoreAfter,
                        command: command,
                        renderGeneration: renderGeneration,
                        isActive: isActive,
                        beforePageID: beforePageID,
                        afterPageID: afterPageID,
                        prefetchResetGeneration: prefetchResetGeneration,
                        onLoadBefore: onLoadBefore,
                        onLoadAfter: onLoadAfter,
                        onSemanticHead: onSemanticHead,
                        onSemanticTail: onSemanticTail,
                        rowContent: rowContent,
                        in: tableView
                    )
                }
                return
            }
            self.hasMoreBefore = hasMoreBefore
            self.hasMoreAfter = hasMoreAfter
            self.onLoadBefore = onLoadBefore
            self.onLoadAfter = onLoadAfter
            self.onSemanticHead = onSemanticHead
            self.onSemanticTail = onSemanticTail
            self.rowContent = rowContent
            tableView.scrollsToTop = isActive

            let pageBoundaryChanged = self.beforePageID != beforePageID
                || self.afterPageID != afterPageID
            let prefetchWasReset = self.prefetchResetGeneration != prefetchResetGeneration
            self.beforePageID = beforePageID
            self.afterPageID = afterPageID
            self.prefetchResetGeneration = prefetchResetGeneration
            if prefetchWasReset {
                prefetchGate.reset()
            }

            let priorRows = rowsByID
            let priorIDs = orderedIDs
            let anchor = firstVisibleAnchor(in: tableView)
            let nextRowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let nextIDs = rows.map(\.id)
            if priorRows == nextRowsByID,
               priorIDs == nextIDs,
               lastRenderGeneration == renderGeneration {
                apply(command, in: tableView)
                if pageBoundaryChanged, !prefetchWasReset {
                    evaluatePrefetch(in: tableView)
                }
                return
            }
            let renderGenerationChanged = lastRenderGeneration != renderGeneration
            lastRenderGeneration = renderGeneration
            rowsByID = nextRowsByID
            orderedIDs = nextIDs
            let changedIDs = rows.compactMap { row in
                priorRows[row.id].map { $0 == row ? nil : row.id } ?? nil
            }
            let appendedCount = ConversationAppendDelta.count(previous: priorIDs, current: orderedIDs)

            if case .detached = followState.wrappedValue, appendedCount > 0 {
                incrementUnseenCount(by: appendedCount, anchor: anchor)
            }

            var snapshot = NSDiffableDataSourceSnapshot<Int, Row.ID>()
            snapshot.appendSections([0])
            snapshot.appendItems(orderedIDs)
            let reconfigurable = renderGenerationChanged
                ? orderedIDs.filter { priorRows[$0] != nil }
                : changedIDs.filter { priorRows[$0] != nil }
            if !reconfigurable.isEmpty {
                snapshot.reconfigureItems(reconfigurable)
            }

            isApplyingUpdate = true
            dataSource?.apply(snapshot, animatingDifferences: false) { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                tableView.layoutIfNeeded()
                if self.isFollowingTail, !tableView.isUserScrollMomentumActive {
                    self.scrollToTail(in: tableView, animated: false)
                } else if let anchor, !tableView.isUserScrollMomentumActive {
                    self.restore(anchor, in: tableView)
                    self.pendingContentUpdateAnchor = anchor
                }
                self.isApplyingUpdate = false
                self.apply(command, in: tableView)
                if pageBoundaryChanged, !prefetchWasReset {
                    self.evaluatePrefetch(in: tableView)
                }
                let pendingUpdate = self.pendingUpdate
                self.pendingUpdate = nil
                pendingUpdate?()
            }
            if dataSource == nil {
                isApplyingUpdate = false
            }
            apply(command, in: tableView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            pendingSemanticScrollTarget = nil
            let anchor = firstVisibleAnchor(in: tableView)
            followState.wrappedValue = .detached(
                anchorID: anchor?.id,
                offset: anchor?.offset ?? 0,
                unseenCount: currentUnseenCount
            )
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingUpdate, let tableView = scrollView as? UITableView else { return }
            evaluatePrefetch(in: tableView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate, let tableView = scrollView as? UITableView else { return }
            attachToTailIfReached(in: tableView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            attachToTailIfReached(in: tableView)
        }

        private func evaluatePrefetch(in tableView: UITableView) {
            guard !isApplyingUpdate else { return }
            let firstBoundary = beforePageID.map(ConversationPrefetchBoundary.page)
                ?? orderedIDs.first.map(ConversationPrefetchBoundary.row)
            let lastBoundary = afterPageID.map(ConversationPrefetchBoundary.page)
                ?? orderedIDs.last.map(ConversationPrefetchBoundary.row)
            if prefetchGate.shouldLoadBefore(
                hasMore: hasMoreBefore,
                distance: tableView.contentOffset.y + tableView.adjustedContentInset.top,
                firstID: firstBoundary
            ) {
                onLoadBefore()
            }
            if prefetchGate.shouldLoadAfter(
                hasMore: hasMoreAfter,
                distance: distanceFromTail(in: tableView),
                lastID: lastBoundary
            ) {
                onLoadAfter()
            }
        }

        private func attachToTailIfReached(in tableView: UITableView) {
            guard distanceFromTail(in: tableView) <= chatTranscriptAtBottomThreshold else { return }
            followState.wrappedValue = .followingTail
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            followState.wrappedValue = .jumpingToHead
            guard !hasMoreBefore else {
                onSemanticHead()
                return false
            }
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            guard let first = orderedIDs.first else { return }
            followState.wrappedValue = .detached(anchorID: first, offset: 0, unseenCount: currentUnseenCount)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView,
                  let target = pendingSemanticScrollTarget
            else { return }
            pendingSemanticScrollTarget = nil
            switch target {
            case .head:
                guard let first = orderedIDs.first else { return }
                followState.wrappedValue = .detached(
                    anchorID: first,
                    offset: 0,
                    unseenCount: currentUnseenCount
                )
            case .tail:
                followState.wrappedValue = .followingTail
            }
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
        }

        private var isFollowingTail: Bool {
            if case .followingTail = followState.wrappedValue { return true }
            return false
        }

        private var currentUnseenCount: Int {
            if case .detached(_, _, let unseenCount) = followState.wrappedValue {
                return unseenCount
            }
            return 0
        }

        private func incrementUnseenCount(by count: Int, anchor: Anchor?) {
            let oldCount = currentUnseenCount
            followState.wrappedValue = .detached(
                anchorID: anchor?.id,
                offset: anchor?.offset ?? 0,
                unseenCount: oldCount + count
            )
        }

        private func apply(_ command: ConversationScrollCommand?, in tableView: UITableView) {
            guard !isApplyingUpdate,
                  let command,
                  command.generation != lastCommandGeneration
            else { return }
            switch command.target {
            case .head:
                guard !hasMoreBefore else {
                    followState.wrappedValue = .jumpingToHead
                    if pendingSemanticCommandGeneration != command.generation {
                        pendingSemanticCommandGeneration = command.generation
                        onSemanticHead()
                    }
                    return
                }
                pendingSemanticCommandGeneration = nil
                lastCommandGeneration = command.generation
                followState.wrappedValue = .jumpingToHead
                scrollToHead(in: tableView, animated: command.animated)
            case .tail:
                guard !hasMoreAfter else {
                    followState.wrappedValue = .jumpingToTail
                    if pendingSemanticCommandGeneration != command.generation {
                        pendingSemanticCommandGeneration = command.generation
                        onSemanticTail()
                    }
                    return
                }
                pendingSemanticCommandGeneration = nil
                lastCommandGeneration = command.generation
                followState.wrappedValue = .followingTail
                scrollToTail(in: tableView, animated: command.animated)
            }
        }

        private func scrollToHead(in tableView: UITableView, animated: Bool) {
            guard !orderedIDs.isEmpty else { return }
            pendingSemanticScrollTarget = animated ? .head : nil
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: -tableView.adjustedContentInset.top),
                animated: animated
            )
            if let first = orderedIDs.first {
                followState.wrappedValue = .detached(
                    anchorID: first,
                    offset: 0,
                    unseenCount: currentUnseenCount
                )
            }
        }

        private func scrollToTail(in tableView: UITableView, animated: Bool) {
            tableView.layoutIfNeeded()
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: maxOffsetY(in: tableView)),
                animated: animated
            )
            (tableView as? ChatTranscriptUITableView)?.recordCurrentViewport()
        }

        private func firstVisibleAnchor(in tableView: UITableView) -> Anchor? {
            guard let indexPath = tableView.indexPathsForVisibleRows?.min(),
                  orderedIDs.indices.contains(indexPath.row)
            else { return nil }
            let rowID = orderedIDs[indexPath.row]
            let offset = tableView.contentOffset.y - tableView.rectForRow(at: indexPath).minY
            return Anchor(id: rowID, offset: offset)
        }

        private func restore(_ anchor: Anchor, in tableView: UITableView) {
            guard let row = orderedIDs.firstIndex(of: anchor.id) else { return }
            let rowTop = tableView.rectForRow(at: IndexPath(row: row, section: 0)).minY
            let desired = rowTop + anchor.offset
            let clamped = min(max(desired, -tableView.adjustedContentInset.top), maxOffsetY(in: tableView))
            tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: clamped), animated: false)
        }

        private func distanceFromTail(in tableView: UITableView) -> CGFloat {
            max(0, maxOffsetY(in: tableView) - tableView.contentOffset.y)
        }

        private func maxOffsetY(in tableView: UITableView) -> CGFloat {
            ConversationTailGeometry.maximumOffset(
                contentHeight: tableView.contentSize.height,
                viewportHeight: tableView.bounds.height,
                topInset: tableView.adjustedContentInset.top,
                bottomInset: tableView.adjustedContentInset.bottom
            )
        }

        private func handleLayoutChange(
            in tableView: ChatTranscriptUITableView,
            oldBoundsSize: CGSize,
            oldContentSize: CGSize,
            oldViewport: MobileScrollViewportSnapshot?,
            oldAnchor: ChatTranscriptTableAnchor?
        ) {
            guard !isHandlingLayout else { return }
            let heightChanged = abs(oldBoundsSize.height - tableView.bounds.height) > 0.5
            let widthChanged = abs(oldBoundsSize.width - tableView.bounds.width) > 0.5
            let contentChanged = abs(oldContentSize.height - tableView.contentSize.height) > 0.5
            guard heightChanged || widthChanged || contentChanged else { return }
            guard !tableView.isUserScrollMomentumActive,
                  !tableView.isViewportInsetsExternallyDriven,
                  !isApplyingUpdate
            else { return }

            isHandlingLayout = true
            defer { isHandlingLayout = false }
            if widthChanged,
               !isFollowingTail,
               let oldAnchor,
               let id = oldAnchor.id.base as? Row.ID {
                restore(Anchor(id: id, offset: oldAnchor.offsetFromRowTop), in: tableView)
            } else if heightChanged, let oldViewport {
                tableView.restoreKeyboardViewport(oldViewport)
            } else if isFollowingTail || oldViewport?.wasAtBottom == true {
                scrollToTail(in: tableView, animated: false)
            } else if contentChanged, let pendingContentUpdateAnchor {
                restore(pendingContentUpdateAnchor, in: tableView)
                self.pendingContentUpdateAnchor = nil
            } else if contentChanged,
                      let oldAnchor,
                      let id = oldAnchor.id.base as? Row.ID {
                restore(Anchor(id: id, offset: oldAnchor.offsetFromRowTop), in: tableView)
            }
            evaluatePrefetch(in: tableView)
        }

        private struct Anchor {
            let id: Row.ID
            let offset: CGFloat
        }
    }
}
#endif
