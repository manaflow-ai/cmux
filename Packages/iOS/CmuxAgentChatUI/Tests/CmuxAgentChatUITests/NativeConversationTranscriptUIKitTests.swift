#if os(iOS)
import CmuxAgentChat
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

    @Test("real prose bubble rows report full multiline height to native sizing")
    func realProseBubbleRowsReportFullMultilineHeight() async throws {
        let firstText = Array(
            repeating: "This actual agent bubble contains enough markdown prose to wrap across many physical lines.",
            count: 42
        ).joined(separator: " ")
        let secondText = Array(
            repeating: "The following user bubble also wraps and must start after the first bubble's painted pixels.",
            count: 30
        ).joined(separator: " ")
        let rows = [
            TranscriptTestRow(id: 0, snapshot: chatSnapshot(id: 0, role: .agent, text: firstText)),
            TranscriptTestRow(id: 1, snapshot: chatSnapshot(id: 1, role: .user, text: secondText)),
            TranscriptTestRow(id: 2, text: "Trailing row"),
        ]
        let mounted = mount(
            TranscriptTestHarness(rows: rows),
            size: CGSize(width: 390, height: 1_400)
        )
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 24)

        let table = try #require(transcriptTable(in: mounted.host.view))
        let firstRect = table.rectForRow(at: IndexPath(row: 0, section: 0))
        let secondRect = table.rectForRow(at: IndexPath(row: 1, section: 0))
        #expect(firstRect.height > 280)
        #expect(secondRect.height > 180)
        #expect(firstRect.maxY <= secondRect.minY + 0.5)
        #expect(!firstRect.insetBy(dx: 0, dy: 0.5).intersects(secondRect.insetBy(dx: 0, dy: 0.5)))

        let firstCell = try #require(table.cellForRow(at: IndexPath(row: 0, section: 0)))
        let secondCell = try #require(table.cellForRow(at: IndexPath(row: 1, section: 0)))
        let firstPaintedFrame = descendantFrameUnion(of: firstCell, in: table)
        let secondPaintedFrame = descendantFrameUnion(of: secondCell, in: table)
        #expect(firstPaintedFrame.maxY <= secondRect.minY + 0.5)
        #expect(!firstPaintedFrame.insetBy(dx: 0, dy: 0.5).intersects(secondPaintedFrame.insetBy(dx: 0, dy: 0.5)))
    }

    @Test("inline image preview reserves a full row without covering its neighbor")
    func inlineImagePreviewDoesNotOverlapFollowingRow() async throws {
        let rows = [
            TranscriptTestRow(
                id: 0,
                attachment: ChatAttachment(
                    media: .image,
                    displayName: "screen.png",
                    hostPath: "/tmp/screen.png",
                    mimeType: "image/png",
                    byteCount: 456_789,
                    pixelWidth: 1_600,
                    pixelHeight: 900
                )
            ),
            TranscriptTestRow(id: 1, text: "Following response"),
        ]
        let mounted = mount(
            TranscriptTestHarness(rows: rows),
            size: CGSize(width: 390, height: 844)
        )
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        let imageRect = table.rectForRow(at: IndexPath(row: 0, section: 0))
        let followingRect = table.rectForRow(at: IndexPath(row: 1, section: 0))
        #expect(imageRect.height >= 180)
        #expect(imageRect.maxY <= followingRect.minY + 0.5)
        #expect(!imageRect.insetBy(dx: 0, dy: 0.5).intersects(followingRect.insetBy(dx: 0, dy: 0.5)))
    }

    @Test("reconfigured visible rows invalidate native height before drawing over neighbors")
    func reconfiguredVisibleRowsInvalidateHeightBeforeDrawingOverNeighbors() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 0, offset: 0, unseenCount: 0))
        let initialRows = [
            TranscriptTestRow(id: 0, text: "Short streamed answer."),
            TranscriptTestRow(id: 1, text: "Following prompt bubble."),
        ]
        var harness = TranscriptTestHarness(rows: initialRows, followState: state)
        let mounted = mount(
            harness,
            size: CGSize(width: 390, height: 1_400)
        )
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 16)

        let table = try #require(transcriptTable(in: mounted.host.view))
        let initialHeight = table.rectForRow(at: IndexPath(row: 0, section: 0)).height
        let expandedText = Array(
            repeating: "The same visible row later resolves into a much taller markdown answer.",
            count: 52
        ).joined(separator: " ")
        harness = TranscriptTestHarness(
            rows: [
                TranscriptTestRow(id: 0, text: expandedText),
                TranscriptTestRow(id: 1, text: "Following prompt bubble."),
            ],
            followState: state
        )
        mounted.host.rootView = harness

        await settle(mounted.host, passes: 32)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        let expandedRect = updatedTable.rectForRow(at: IndexPath(row: 0, section: 0))
        let followingRect = updatedTable.rectForRow(at: IndexPath(row: 1, section: 0))
        #expect(expandedRect.height > initialHeight + 240)
        #expect(expandedRect.maxY <= followingRect.minY + 0.5)
        #expect(!expandedRect.insetBy(dx: 0, dy: 0.5).intersects(followingRect.insetBy(dx: 0, dy: 0.5)))

        let expandedCell = try #require(updatedTable.cellForRow(at: IndexPath(row: 0, section: 0)))
        let paintedFrame = descendantFrameUnion(of: expandedCell, in: updatedTable)
        #expect(paintedFrame.maxY <= followingRect.minY + 0.5)
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

    @Test("tail command reaches the real last row in a ten-thousand-row window")
    func tailCommandReachesRealLastRowInTenThousandRowWindow() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 5_000, offset: 0, unseenCount: 0))
        let wrappedTailText = Array(
            repeating: "The final row is much taller than the estimated row height.",
            count: 120
        ).joined(separator: " ")
        let rows = (0..<10_000).map {
            TranscriptTestRow(
                id: $0,
                text: $0 == 9_999 ? wrappedTailText : "Compact response \($0)"
            )
        }
        let harness = TranscriptTestHarness(
            rows: rows,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail, animated: false)
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 64)

        let table = try #require(transcriptTable(in: mounted.host.view))
        let visibleRows = try #require(table.indexPathsForVisibleRows)
        #expect(table.numberOfRows(inSection: 0) == 10_000)
        #expect(visibleRows.contains(IndexPath(row: 9_999, section: 0)))
        #expect(distanceFromTail(in: table) <= 1.5)
        #expect(state.value == .followingTail)
        #expect(table.visibleCells.count < 80)
    }

    @Test("reused hosted cells reset row-local SwiftUI state by row identity")
    func reusedHostedCellsResetRowLocalSwiftUIStateByRowIdentity() async throws {
        let rows = (0..<220).map { TranscriptTestRow(id: $0, stateProbe: true) }
        let mounted = mount(
            TranscriptTestHarness(rows: rows),
            size: CGSize(width: 390, height: 260)
        )
        defer { mounted.window.isHidden = true }

        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        table.scrollToRow(at: IndexPath(row: 180, section: 0), at: .top, animated: false)
        await settle(mounted.host, passes: 24)

        let visibleRows = try #require(table.indexPathsForVisibleRows)
        #expect(!visibleRows.isEmpty)
        #expect(table.visibleCells.count < 20)
        for indexPath in visibleRows {
            #expect(table.rectForRow(at: indexPath).height < 100)
        }
    }

    @Test("detached animated tail command converges after wrapped rows resolve")
    func detachedAnimatedTailCommandConvergesAfterWrappedRowsResolve() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 120, offset: 0, unseenCount: 0))
        let wrappedText = Array(repeating: "Resolved transcript text can be much taller than its estimated table height.", count: 120)
            .joined(separator: " ")
        let rows = (0..<180).map {
            TranscriptTestRow(id: $0, text: $0 == 179 ? wrappedText : "Compact response \($0)")
        }
        var harness = TranscriptTestHarness(rows: rows, followState: state)
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        table.layoutIfNeeded()
        table.setContentOffset(
            CGPoint(x: 0, y: table.rectForRow(at: IndexPath(row: 120, section: 0)).minY),
            animated: false
        )
        await settle(mounted.host, passes: 4)
        #expect(distanceFromTail(in: table) > 400)

        harness = TranscriptTestHarness(
            rows: rows,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail)
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 48)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        #expect(state.value == .followingTail)
        #expect(distanceFromTail(in: updatedTable) <= 1.5)
    }

    @Test("tail command does not report following while the last row is not visible")
    func tailCommandWaitsForVisibleLastRowBeforeFollowing() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 120, offset: 0, unseenCount: 0))
        let wrappedText = Array(repeating: "Resolved transcript text can be much taller than its estimated table height.", count: 120)
            .joined(separator: " ")
        let rows = (0..<180).map {
            TranscriptTestRow(id: $0, text: $0 == 179 ? wrappedText : "Compact response \($0)")
        }
        var harness = TranscriptTestHarness(rows: rows, followState: state)
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        table.layoutIfNeeded()
        table.setContentOffset(
            CGPoint(x: 0, y: table.rectForRow(at: IndexPath(row: 120, section: 0)).minY),
            animated: false
        )
        await settle(mounted.host, passes: 4)

        harness = TranscriptTestHarness(
            rows: rows,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail)
        )
        mounted.host.rootView = harness

        for _ in 0..<12 {
            await settle(mounted.host, passes: 1)
            if state.value == .followingTail {
                let visibleRows = table.indexPathsForVisibleRows ?? []
                #expect(visibleRows.contains(IndexPath(row: rows.count - 1, section: 0)))
                #expect(distanceFromTail(in: table) <= 1.5)
            }
        }
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

    @Test("status-bar scrolling cancels an in-flight tail settle")
    func statusBarScrollingCancelsInFlightTailSettle() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 120, offset: 0, unseenCount: 0))
        let wrappedTailText = Array(
            repeating: "The final streamed answer resolves into a much taller row after the first tail jump.",
            count: 160
        ).joined(separator: " ")
        let rows = (0..<240).map {
            TranscriptTestRow(
                id: $0,
                text: $0 == 239 ? wrappedTailText : "Compact response \($0)"
            )
        }
        let mounted = mount(TranscriptTestHarness(
            rows: rows,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail, animated: false)
        ))
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 1)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(distanceFromTail(in: table) <= 1.5)
        #expect(table.delegate?.scrollViewShouldScrollToTop?(table) == true)
        table.setContentOffset(
            CGPoint(x: table.contentOffset.x, y: -table.adjustedContentInset.top),
            animated: false
        )
        table.delegate?.scrollViewDidScrollToTop?(table)
        await settle(mounted.host, passes: 8)

        #expect(abs(table.contentOffset.y + table.adjustedContentInset.top) <= 1.5)
        #expect(distanceFromTail(in: table) > 1_000)
        #expect(state.value == .detached(anchorID: rows[0].id, offset: 0, unseenCount: 0))
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

    @Test("semantic head loads the authoritative window then reaches its real top")
    func semanticHeadLoadsAuthoritativeWindowAndReachesTop() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 9_960, offset: 0, unseenCount: 0))
        let callbacks = TranscriptCallbackBox()
        var harness = TranscriptTestHarness(
            rows: (9_920..<10_000).map { TranscriptTestRow(id: $0, text: "Loaded response \($0)") },
            hasMoreBefore: true,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .head, animated: false),
            onSemanticHead: { callbacks.semanticHeadCount += 1 }
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(callbacks.semanticHeadCount == 1)
        #expect(state.value == .jumpingToHead)

        let authoritativeRows = (0..<80).map {
            TranscriptTestRow(id: $0, text: "Authoritative head response \($0)")
        }
        harness = TranscriptTestHarness(
            rows: authoritativeRows,
            hasMoreBefore: false,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .head, animated: false),
            onSemanticHead: { callbacks.semanticHeadCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 24)

        let updatedTable = try #require(transcriptTable(in: mounted.host.view))
        #expect(updatedTable === table)
        #expect(callbacks.semanticHeadCount == 1)
        #expect(state.value == .detached(anchorID: authoritativeRows[0].id, offset: 0, unseenCount: 0))
        #expect(abs(updatedTable.contentOffset.y + updatedTable.adjustedContentInset.top) <= 1.5)
        let visibleRows = try #require(updatedTable.indexPathsForVisibleRows)
        #expect(visibleRows.contains(IndexPath(row: 0, section: 0)))
    }

    @Test("semantic head command advances across multiple page boundaries")
    func semanticHeadCommandAdvancesAcrossMultiplePageBoundaries() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 200, offset: 0, unseenCount: 0))
        let callbacks = TranscriptCallbackBox()
        var harness = TranscriptTestHarness(
            rows: (160..<240).map { TranscriptTestRow(id: $0, text: "Loaded response \($0)") },
            hasMoreBefore: true,
            beforePageID: "older-c",
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .head, animated: false),
            onSemanticHead: { callbacks.semanticHeadCount += 1 }
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        #expect(callbacks.semanticHeadCount == 1)
        #expect(state.value == .jumpingToHead)

        harness = TranscriptTestHarness(
            rows: (80..<160).map { TranscriptTestRow(id: $0, text: "Loaded response \($0)") },
            hasMoreBefore: true,
            beforePageID: "older-b",
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .head, animated: false),
            onSemanticHead: { callbacks.semanticHeadCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 20)

        #expect(callbacks.semanticHeadCount == 2)
        #expect(state.value == .jumpingToHead)

        mounted.host.rootView = harness
        await settle(mounted.host, passes: 8)
        #expect(callbacks.semanticHeadCount == 2)

        let authoritativeRows = (0..<80).map {
            TranscriptTestRow(id: $0, text: "Authoritative head response \($0)")
        }
        harness = TranscriptTestHarness(
            rows: authoritativeRows,
            hasMoreBefore: false,
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .head, animated: false),
            onSemanticHead: { callbacks.semanticHeadCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 24)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(callbacks.semanticHeadCount == 2)
        #expect(state.value == .detached(anchorID: authoritativeRows[0].id, offset: 0, unseenCount: 0))
        #expect(abs(table.contentOffset.y + table.adjustedContentInset.top) <= 1.5)
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

    @Test("top prefetch uses opaque page boundaries and reset retries")
    func topPrefetchUsesOpaquePageBoundariesAndResetRetries() async throws {
        let rows = (80..<160).map { TranscriptTestRow(id: $0, text: "Response \($0)") }
        let callbacks = TranscriptCallbackBox()
        let state = TranscriptFollowStateBox(.detached(anchorID: 100, offset: 0, unseenCount: 0))
        var harness = TranscriptTestHarness(
            rows: rows,
            hasMoreBefore: true,
            beforePageID: "older-page-a",
            followState: state,
            onLoadBefore: { callbacks.loadBeforeCount += 1 }
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 16)

        let table = try #require(transcriptTable(in: mounted.host.view))
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.delegate?.scrollViewDidScroll?(table)
        #expect(callbacks.loadBeforeCount == 1)
        #expect(isDetached(state.value))

        table.delegate?.scrollViewDidScroll?(table)
        #expect(callbacks.loadBeforeCount == 1)

        harness = TranscriptTestHarness(
            rows: rows,
            hasMoreBefore: true,
            beforePageID: "older-page-b",
            followState: state,
            onLoadBefore: { callbacks.loadBeforeCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 10)
        #expect(callbacks.loadBeforeCount == 2)

        harness = TranscriptTestHarness(
            rows: rows,
            hasMoreBefore: true,
            beforePageID: "older-page-b",
            prefetchResetGeneration: 1,
            followState: state,
            onLoadBefore: { callbacks.loadBeforeCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 8)
        table.delegate?.scrollViewDidScroll?(table)
        #expect(callbacks.loadBeforeCount == 3)
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

    @Test("semantic tail command advances across multiple page boundaries")
    func semanticTailCommandAdvancesAcrossMultiplePageBoundaries() async throws {
        let state = TranscriptFollowStateBox(.detached(anchorID: 40, offset: 0, unseenCount: 0))
        let callbacks = TranscriptCallbackBox()
        var harness = TranscriptTestHarness(
            rows: (0..<80).map { TranscriptTestRow(id: $0, text: "Loaded response \($0)") },
            hasMoreAfter: true,
            afterPageID: "newer-a",
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail, animated: false),
            onSemanticTail: { callbacks.semanticTailCount += 1 }
        )
        let mounted = mount(harness)
        defer { mounted.window.isHidden = true }
        await settle(mounted.host, passes: 20)

        #expect(callbacks.semanticTailCount == 1)
        #expect(state.value == .jumpingToTail)

        harness = TranscriptTestHarness(
            rows: (80..<160).map { TranscriptTestRow(id: $0, text: "Loaded response \($0)") },
            hasMoreAfter: true,
            afterPageID: "newer-b",
            followState: state,
            command: ConversationScrollCommand(generation: 1, target: .tail, animated: false),
            onSemanticTail: { callbacks.semanticTailCount += 1 }
        )
        mounted.host.rootView = harness
        await settle(mounted.host, passes: 20)

        #expect(callbacks.semanticTailCount == 2)
        #expect(state.value == .jumpingToTail)

        mounted.host.rootView = harness
        await settle(mounted.host, passes: 8)
        #expect(callbacks.semanticTailCount == 2)

        let authoritativeRows = (160..<240).map {
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
        await settle(mounted.host, passes: 32)

        let table = try #require(transcriptTable(in: mounted.host.view))
        #expect(callbacks.semanticTailCount == 2)
        #expect(state.value == .followingTail)
        #expect(distanceFromTail(in: table) <= 1.5)
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

    private func descendantFrameUnion(of view: UIView, in coordinateSpace: UIView) -> CGRect {
        var union = CGRect.null
        for subview in view.subviews {
            union = union.union(subview.convert(subview.bounds, to: coordinateSpace))
            union = union.union(descendantFrameUnion(of: subview, in: coordinateSpace))
        }
        return union.isNull ? view.convert(view.bounds, to: coordinateSpace) : union
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

    private func chatSnapshot(id: Int, role: ChatRole, text: String) -> ChatMessageRowSnapshot {
        ChatMessageRowSnapshot(
            message: ChatMessage(
                id: "chat-\(id)",
                seq: id,
                role: role,
                timestamp: Date(timeIntervalSince1970: TimeInterval(id)),
                kind: .prose(ChatProse(text: text))
            ),
            groupPosition: .solo,
            showsTimestamp: false
        )
    }

    private func isDetached(_ state: ConversationFollowState<Int>) -> Bool {
        if case .detached = state { return true }
        return false
    }
}

private struct TranscriptTestRow: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String)
        case message(ChatMessageRowSnapshot)
        case attachment(ChatAttachment)
        case stateProbe
    }

    let id: Int
    let content: Content

    init(id: Int, text: String) {
        self.id = id
        content = .text(text)
    }

    init(id: Int, snapshot: ChatMessageRowSnapshot) {
        self.id = id
        content = .message(snapshot)
    }

    init(id: Int, attachment: ChatAttachment) {
        self.id = id
        content = .attachment(attachment)
    }

    init(id: Int, stateProbe: Bool) {
        self.id = id
        content = .stateProbe
    }
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
    var loadBeforeCount = 0
    var loadAfterCount = 0
}

@MainActor
private struct TranscriptTestHarness: View {
    let rows: [TranscriptTestRow]
    var hasMoreBefore = false
    var hasMoreAfter = false
    var isActive = true
    var beforePageID: String?
    var afterPageID: String?
    var prefetchResetGeneration = 0
    var followState: TranscriptFollowStateBox
    var command: ConversationScrollCommand?
    var onLoadBefore: () -> Void
    var onLoadAfter: () -> Void
    var onSemanticHead: () -> Void
    var onSemanticTail: () -> Void

    init(
        rows: [TranscriptTestRow],
        hasMoreBefore: Bool = false,
        hasMoreAfter: Bool = false,
        isActive: Bool = true,
        beforePageID: String? = nil,
        afterPageID: String? = nil,
        prefetchResetGeneration: Int = 0,
        followState: TranscriptFollowStateBox = TranscriptFollowStateBox(.detached(
            anchorID: nil,
            offset: 0,
            unseenCount: 0
        )),
        command: ConversationScrollCommand? = nil,
        onLoadBefore: @escaping () -> Void = {},
        onLoadAfter: @escaping () -> Void = {},
        onSemanticHead: @escaping () -> Void = {},
        onSemanticTail: @escaping () -> Void = {}
    ) {
        self.rows = rows
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.isActive = isActive
        self.beforePageID = beforePageID
        self.afterPageID = afterPageID
        self.prefetchResetGeneration = prefetchResetGeneration
        self.followState = followState
        self.command = command
        self.onLoadBefore = onLoadBefore
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
            beforePageID: beforePageID,
            afterPageID: afterPageID,
            prefetchResetGeneration: prefetchResetGeneration,
            onLoadBefore: onLoadBefore,
            onLoadAfter: onLoadAfter,
            onSemanticHead: onSemanticHead,
            onSemanticTail: onSemanticTail
        ) { row in
            switch row.content {
            case .text(let text):
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            case .message(let snapshot):
                ChatMessageRowView(
                    snapshot: snapshot,
                    actions: ChatRowActions()
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            case .attachment(let attachment):
                ChatAttachmentBubbleView(
                    attachment: attachment,
                    groupPosition: .solo,
                    showsTimestamp: false,
                    timestamp: Date(timeIntervalSince1970: 0)
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            case .stateProbe:
                TranscriptStateProbeRowView(rowID: row.id)
            }
        }
    }
}

private struct TranscriptStateProbeRowView: View {
    let rowID: Int
    @State private var stateOwnerRowID: Int?

    var body: some View {
        Text(verbatim: "State probe \(rowID)")
            .font(.system(size: 16))
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: stateLeaked ? 240 : 36)
            .padding(.horizontal, 16)
            .onAppear {
                if stateOwnerRowID == nil {
                    stateOwnerRowID = rowID
                }
            }
    }

    private var stateLeaked: Bool {
        guard let stateOwnerRowID else { return false }
        return stateOwnerRowID != rowID
    }
}
#endif
