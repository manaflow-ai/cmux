#if os(iOS)
import SwiftUI
import Testing
import UIKit

@testable import CmuxAgentChatUI

@MainActor
@Suite("Native conversation transcript UIKit behavior", .serialized)
struct NativeConversationTranscriptUIKitTests {
    @Test("ten thousand rows keep a bounded native cell set")
    func tenThousandRowsKeepBoundedCells() async throws {
        let rows = (0..<10_000).map {
            TranscriptTestRow(id: $0, text: "Message \($0)")
        }
        let harness = TranscriptTestHarness(rows: rows)
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 16)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(table.numberOfRows(inSection: 0) == 10_000)
        #expect(!table.visibleCells.isEmpty)
        #expect(table.visibleCells.count < 80)
        #expect(descendants(of: UITableViewCell.self, in: table).count < 80)
    }

    @Test("adjacent very long wrapped rows have disjoint native row rects")
    func longWrappedRowsDoNotOverlap() async throws {
        let firstText = Array(repeating: "A long first response wraps at the transcript width.", count: 36)
            .joined(separator: " ")
        let secondText = Array(repeating: "A long second response also wraps without covering its neighbor.", count: 36)
            .joined(separator: " ")
        let rows = [
            TranscriptTestRow(id: 0, text: firstText),
            TranscriptTestRow(id: 1, text: secondText),
            TranscriptTestRow(id: 2, text: "Trailing row"),
        ]
        let mounted = mount(
            TranscriptTestHarness(rows: rows),
            size: CGSize(width: 390, height: 1_400)
        )
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        let firstRect = table.rectForRow(at: IndexPath(row: 0, section: 0))
        let secondRect = table.rectForRow(at: IndexPath(row: 1, section: 0))
        #expect(firstRect.height > 200)
        #expect(secondRect.height > 200)
        #expect(firstRect.maxY <= secondRect.minY + 0.5)
        #expect(!firstRect.insetBy(dx: 0, dy: 0.5).intersects(secondRect.insetBy(dx: 0, dy: 0.5)))

        let firstCell = try #require(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        let secondCell = try #require(table.cellForRow(at: IndexPath(row: 1, section: 0)))
        #expect(firstCell.frame.maxY <= secondCell.frame.minY + 0.5)
    }

    @Test("detached first-visible anchor survives a prepend")
    func detachedAnchorSurvivesPrepend() async throws {
        let initialRows = (100..<240).map {
            TranscriptTestRow(id: $0, text: "Existing response \($0)")
        }
        let state = TranscriptFollowStateBox(.detached(anchorID: 160, offset: 13, unseenCount: 0))
        var harness = TranscriptTestHarness(rows: initialRows, followState: state)
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 16)

        let table = try #require(transcriptTable(in: mounted.host.view))
        let requestedIndex = IndexPath(row: 60, section: 0)
        table.layoutIfNeeded()
        table.setContentOffset(
            CGPoint(x: 0, y: table.rectForRow(at: requestedIndex).minY + 13),
            animated: false
        )
        await settle(mounted.host, passes: 4)

        let before = try #require(firstVisibleAnchor(in: table, rows: initialRows))
        state.value = .detached(anchorID: before.id, offset: before.offset, unseenCount: 0)

        let prependedRows = (0..<100).map {
            TranscriptTestRow(id: $0, text: "Older response \($0)")
        } + initialRows
        harness = TranscriptTestHarness(rows: prependedRows, followState: state)
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 24)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        let after = try #require(firstVisibleAnchor(in: updatedTable, rows: prependedRows))
        #expect(after.id == before.id)
        #expect(abs(after.offset - before.offset) <= 1.5)
    }

    @Test("following tail converges after appended wrapped rows self-size")
    func followingTailConvergesAfterSelfSizingAppend() async throws {
        let state = TranscriptFollowStateBox(.followingTail)
        let initialRows = (0..<160).map {
            TranscriptTestRow(id: $0, text: "Compact response \($0)")
        }
        var harness = TranscriptTestHarness(rows: initialRows, followState: state)
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(distanceFromTail(in: table) <= 1.5)

        let wrappedText = Array(repeating: "The final streamed answer resolves into substantially more wrapped content.", count: 120)
            .joined(separator: " ")
        harness = TranscriptTestHarness(
            rows: initialRows + [TranscriptTestRow(id: 160, text: wrappedText)],
            followState: state
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 32)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        #expect(updatedTable.contentSize.height > 10_000)
        #expect(distanceFromTail(in: updatedTable) <= 1.5)
        #expect(abs(updatedTable.contentOffset.y - maximumOffset(in: updatedTable)) <= 1.5)
    }

    @Test("only the active transcript owns native status-bar scroll-to-top")
    func activeTranscriptOwnsScrollToTop() async throws {
        let rows = (0..<20).map { TranscriptTestRow(id: $0, text: "Response \($0)") }
        var harness = TranscriptTestHarness(rows: rows, isActive: false)
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 12)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(!table.scrollsToTop)

        harness = TranscriptTestHarness(rows: rows, isActive: true)
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 8)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        #expect(updatedTable.scrollsToTop)
    }

    @Test("status-bar scrolling detaches before UIKit begins its animation")
    func statusBarScrollingDetachesBeforeAnimation() async throws {
        let rows = (0..<80).map { TranscriptTestRow(id: $0, text: "Response \($0)") }
        let state = TranscriptFollowStateBox(.followingTail)
        let mounted = mount(TranscriptTestHarness(rows: rows, followState: state))
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 12)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(table.delegate?.scrollViewShouldScrollToTop?(table) == true)
        #expect(state.value == .jumpingToHead)
    }

    @Test("status-bar scrolling requests the authoritative head when history is paged")
    func statusBarScrollingRequestsAuthoritativeHead() async throws {
        let callbacks = TranscriptCallbackBox()
        let state = TranscriptFollowStateBox(.followingTail)
        let mounted = mount(TranscriptTestHarness(
            rows: (80..<160).map { TranscriptTestRow(id: $0, text: "Response \($0)") },
            hasMoreBefore: true,
            followState: state,
            onSemanticHead: { callbacks.semanticHeadCount += 1 }
        ))
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 12)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(table.delegate?.scrollViewShouldScrollToTop?(table) == false)
        #expect(callbacks.semanticHeadCount == 1)
        #expect(state.value == .jumpingToHead)
    }

    @Test("opaque page boundaries and reset generations permit edge retries")
    func opaquePageBoundariesAndResetPermitRetries() async throws {
        let rows = (0..<12).map { TranscriptTestRow(id: $0, text: "Response \($0)") }
        let callbacks = TranscriptCallbackBox()
        let state = TranscriptFollowStateBox(.detached(anchorID: 0, offset: 0, unseenCount: 0))
        var harness = TranscriptTestHarness(
            rows: rows,
            hasMoreAfter: true,
            afterPageID: "opaque-page-a",
            followState: state,
            onLoadAfter: { callbacks.loadAfterCount += 1 }
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 16)

        let table = try #require(transcriptTable(in: mounted.host.view))
        table.setContentOffset(CGPoint(x: 0, y: maximumOffset(in: table)), animated: false)
        table.delegate?.scrollViewDidScroll?(table)
        #expect(callbacks.loadAfterCount == 1)
        #expect(isDetached(state.value))

        harness = TranscriptTestHarness(
            rows: rows,
            hasMoreAfter: true,
            afterPageID: "opaque-page-b",
            followState: state,
            onLoadAfter: { callbacks.loadAfterCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 10)
        #expect(callbacks.loadAfterCount == 2)

        harness = TranscriptTestHarness(
            rows: rows,
            hasMoreAfter: true,
            afterPageID: "opaque-page-b",
            prefetchResetGeneration: 1,
            followState: state,
            onLoadAfter: { callbacks.loadAfterCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 8)
        table.delegate?.scrollViewDidScroll?(table)
        #expect(callbacks.loadAfterCount == 3)
    }

    @Test("semantic tail loads the authoritative window then reaches its real bottom")
    func semanticTailLoadsAuthoritativeWindowAndReachesBottom() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 40, offset: 0, unseenCount: 0))
        let callbacks = TranscriptCallbackBox()
        var harness = TranscriptTestHarness(
            rows: (0..<80).map { TranscriptTestRow(id: $0, text: "Loaded response \($0)") },
            hasMoreAfter: true,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail, animated: false),
            onSemanticTail: { callbacks.semanticTailCount += 1 }
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(callbacks.semanticTailCount == 1)
        #expect(state.value == .jumpingToTail)

        let authoritativeRows = (9_920..<10_000).map {
            TranscriptTestRow(id: $0, text: "Authoritative tail response \($0)")
        }
        harness = TranscriptTestHarness(
            rows: authoritativeRows,
            hasMoreAfter: false,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail, animated: false),
            onSemanticTail: { callbacks.semanticTailCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 24)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        #expect(callbacks.semanticTailCount == 1)
        #expect(state.value == .followingTail)
        #expect(distanceFromTail(in: updatedTable) <= 1.5)
        let visibleRows = try #require(updatedTable.indexPathsForVisibleRows)
        #expect(visibleRows.contains(IndexPath(row: authoritativeRows.count - 1, section: 0)))
    }

    private func mount(
        _ harness: TranscriptTestHarness,
        size: CGSize = CGSize(width: 390, height: 844)
    ) -> (host: UIHostingController<TranscriptTestHarness>, window: UIWindow) {
        let host = UIHostingController(rootView: harness)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return (host, window)
    }

    private func settle(
        _ host: UIHostingController<TranscriptTestHarness>,
        passes: Int
    ) async {
        for _ in 0..<passes {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func transcriptTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView,
           table.accessibilityIdentifier == "NativeConversationTranscript" {
            return table
        }
        for subview in view.subviews {
            if let table = transcriptTable(in: subview) {
                return table
            }
        }
        return nil
    }

    private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var matches = view.subviews.compactMap { $0 as? T }
        for subview in view.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }

    private func firstVisibleAnchor(
        in table: UITableView,
        rows: [TranscriptTestRow]
    ) -> (id: Int, offset: CGFloat)? {
        guard let indexPath = table.indexPathsForVisibleRows?.min(),
              rows.indices.contains(indexPath.row)
        else { return nil }
        return (
            rows[indexPath.row].id,
            table.contentOffset.y - table.rectForRow(at: indexPath).minY
        )
    }

    private func maximumOffset(in table: UITableView) -> CGFloat {
        max(
            -table.adjustedContentInset.top,
            table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom
        )
    }

    private func distanceFromTail(in table: UITableView) -> CGFloat {
        max(0, maximumOffset(in: table) - table.contentOffset.y)
    }

    private func isDetached(_ state: ConversationFollowState<Int>) -> Bool {
        if case .detached = state { return true }
        return false
    }
}

private struct TranscriptTestRow: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
}

@MainActor
private final class TranscriptFollowStateBox {
    var value: ConversationFollowState<Int>

    init(_ value: ConversationFollowState<Int>) {
        self.value = value
    }
}

@MainActor
private final class TranscriptCallbackBox {
    var semanticHeadCount = 0
    var semanticTailCount = 0
    var loadAfterCount = 0
}

@MainActor
private struct TranscriptTestHarness: View {
    let rows: [TranscriptTestRow]
    var hasMoreBefore = false
    var hasMoreAfter = false
    var isActive = true
    var afterPageID: String?
    var prefetchResetGeneration = 0
    var followState: TranscriptFollowStateBox
    var command: ConversationScrollCommand?
    var onLoadAfter: () -> Void
    var onSemanticHead: () -> Void
    var onSemanticTail: () -> Void

    init(
        rows: [TranscriptTestRow],
        hasMoreBefore: Bool = false,
        hasMoreAfter: Bool = false,
        isActive: Bool = true,
        afterPageID: String? = nil,
        prefetchResetGeneration: Int = 0,
        followState: TranscriptFollowStateBox = TranscriptFollowStateBox(.detached(
            anchorID: nil,
            offset: 0,
            unseenCount: 0
        )),
        command: ConversationScrollCommand? = nil,
        onLoadAfter: @escaping () -> Void = {},
        onSemanticHead: @escaping () -> Void = {},
        onSemanticTail: @escaping () -> Void = {}
    ) {
        self.rows = rows
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.isActive = isActive
        self.afterPageID = afterPageID
        self.prefetchResetGeneration = prefetchResetGeneration
        self.followState = followState
        self.command = command
        self.onLoadAfter = onLoadAfter
        self.onSemanticHead = onSemanticHead
        self.onSemanticTail = onSemanticTail
    }

    var body: some View {
        NativeConversationTranscript(
            rows: rows,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            followState: Binding(
                get: { followState.value },
                set: { followState.value = $0 }
            ),
            command: command,
            isActive: isActive,
            afterPageID: afterPageID,
            prefetchResetGeneration: prefetchResetGeneration,
            onLoadAfter: onLoadAfter,
            onSemanticHead: onSemanticHead,
            onSemanticTail: onSemanticTail
        ) { row in
            Text(row.text)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }
}
#endif
