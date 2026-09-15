#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import Testing
import UIKit

@testable import CmuxMobileTerminal

@MainActor
@Suite("Verified replay geometry fit", .serialized)
struct VerifiedReplayGeometryFitTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    @Test("verified replay fits a one-row effective-grid difference exactly")
    func verifiedReplayFitsOneRowDifferenceExactly() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer {
            view.verifiedReplayRenderSuppressed = false
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let mounted = await waitUntil(timeout: .seconds(5)) {
            let snapshot = view.debugGeometrySnapshotForTesting()
            guard let rendered = snapshot.renderedSize,
                  let reported = snapshot.reportedSize else {
                return false
            }
            return snapshot.renderRect.width > 0
                && rendered.columns == reported.columns
                && rendered.rows == reported.rows
                && rendered.columns > 1
                && rendered.rows > 1
        }
        let natural = try #require(view.debugGeometrySnapshotForTesting().renderedSize)
        #expect(mounted)

        view.verifiedReplayRenderSuppressed = true
        let targetRows = natural.rows - 1
        let applied = await view.applyViewSizeAndWait(
            cols: natural.columns,
            rows: targetRows
        )
        let rendered = try #require(view.debugGeometrySnapshotForTesting().renderedSize)

        #expect(applied)
        #expect(rendered.columns == natural.columns)
        #expect(rendered.rows == targetRows)
    }

    @Test("verified replay waits for a larger grid to fit, then resolves it exactly")
    func verifiedReplayFitsOneColumnLargerAfterViewportGrowth() async throws {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer {
            view.verifiedReplayRenderSuppressed = false
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let mounted = await waitUntil(timeout: .seconds(5)) {
            let snapshot = view.debugGeometrySnapshotForTesting()
            guard let rendered = snapshot.renderedSize,
                  let reported = snapshot.reportedSize else {
                return false
            }
            return snapshot.renderRect.width > 0
                && rendered.columns == reported.columns
                && rendered.rows == reported.rows
                && rendered.columns > 1
        }
        let naturalSnapshot = view.debugGeometrySnapshotForTesting()
        let natural = try #require(naturalSnapshot.renderedSize)
        #expect(mounted)

        view.verifiedReplayRenderSuppressed = true
        let targetColumns = natural.columns + 1
        let appliedBeforeGrowth = await view.applyViewSizeAndWait(
            cols: targetColumns,
            rows: natural.rows
        )
        let beforeGrowth = try #require(view.debugGeometrySnapshotForTesting().renderedSize)

        #expect(appliedBeforeGrowth && beforeGrowth.columns == natural.columns)

        growViewportByOneColumn(
            view: view,
            window: window,
            snapshot: naturalSnapshot,
            columns: natural.columns
        )

        let resolved = await waitUntil(timeout: .seconds(5)) {
            view.debugGeometrySnapshotForTesting().renderedSize?.columns == targetColumns
        }
        let afterGrowth = try #require(view.debugGeometrySnapshotForTesting().renderedSize)

        #expect(resolved && afterGrowth.columns == targetColumns)
    }

    @Test("unchanged geometry preserves pinned styled rows and the next primary delta")
    func unchangedGeometryPreservesPinnedRowsAndDeltaBaseline() async throws {
        let mounted = try await mountSurface()
        defer { dismantle(mounted) }
        let view = mounted.view
        let size = pinnedSize(inside: mounted.natural)
        #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
        let frame = try numberedFrame(size: size, theme: view.terminalConfigTheme)
        #expect(await apply(frame, to: view))
        let expected = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
        let baseline = try await observe(view, matching: frame)
        expectRows(baseline.frame, equalTo: expected)
        #expect(baseline.appliedGeneration == baseline.gridGeneration)

        for _ in 0..<6 {
            // A repeated safe-area notification is a real geometry entrypoint
            // even when its values and the effective grid have not changed.
            // Awaiting the same size alone would skip the geometry pass.
            view.safeAreaInsetsDidChange()
            #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
            let observed = try await observe(view, matching: frame)
            expectRows(observed.frame, equalTo: expected)
            #expect(observed.gridGeneration == baseline.gridGeneration)
            #expect(observed.appliedGeneration == baseline.appliedGeneration)
        }

        let delta = try typedDelta(for: frame)
        #expect(await apply(delta, to: view))
        let afterDelta = try await observe(view, matching: delta)
        expectRows(afterDelta.frame, equalTo: try #require(expected.applying(delta)))
        #expect(afterDelta.gridGeneration == baseline.gridGeneration)
        #expect(afterDelta.appliedGeneration == baseline.appliedGeneration)
    }

    @Test("a real pinned-grid size round trip rejects stale deltas until full replay")
    func sizeRoundTripRequiresFreshBaselineBeforeDelta() async throws {
        let mounted = try await mountSurface()
        defer { dismantle(mounted) }
        let view = mounted.view
        let size = pinnedSize(inside: mounted.natural)
        #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
        let frame = try numberedFrame(size: size, theme: view.terminalConfigTheme)
        #expect(await apply(frame, to: view))
        let baseline = try await observe(view, matching: frame)

        let intermediate = TerminalGridSize(
            columns: size.columns - 2,
            rows: size.rows - 2,
            pixelWidth: size.pixelWidth,
            pixelHeight: size.pixelHeight
        )
        #expect(await view.applyViewSizeAndWait(cols: intermediate.columns, rows: intermediate.rows))
        let grown = try await observe(view, matching: frame)
        #expect(grown.frame.columns == intermediate.columns)
        #expect(grown.frame.rows == intermediate.rows)
        #expect(grown.gridGeneration != baseline.gridGeneration)
        #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
        let returned = try await observe(view, matching: frame)
        #expect(returned.frame.columns == size.columns)
        #expect(returned.frame.rows == size.rows)
        #expect(returned.gridGeneration != grown.gridGeneration)
        #expect(returned.appliedGeneration == baseline.appliedGeneration)

        let delta = try typedDelta(for: frame)
        #expect(await apply(delta, to: view) == false)
        let rejected = try await observe(view, matching: frame)
        expectRows(
            rejected.frame,
            equalTo: try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: returned.frame))
        )
        #expect(rejected.appliedGeneration == baseline.appliedGeneration)

        #expect(await apply(frame, to: view))
        let replayed = try await observe(view, matching: frame)
        let expected = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: frame))
        expectRows(replayed.frame, equalTo: expected)
        #expect(replayed.appliedGeneration == returned.gridGeneration)
        #expect(await apply(delta, to: view))
        let afterDelta = try await observe(view, matching: delta)
        expectRows(afterDelta.frame, equalTo: try #require(expected.applying(delta)))
    }

    @Test("raw VT output survives repeated no-op geometry with history and wrapped prompts")
    func rawVTOutputSurvivesNoOpGeometry() async throws {
        let mounted = try await mountSurface()
        defer { dismantle(mounted) }
        let view = mounted.view
        let size = pinnedSize(inside: mounted.natural)
        #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))

        // Keep ANSI control bytes outside the visible payload. Ghostty counts
        // only the plain text toward wrapping, so styling the complete line
        // must happen after constructing a payload that is longer than one
        // viewport row.
        let lineWidth = max(size.columns * 2 + 7, 32)
        var output = "\u{1B}[?2026h"
        for row in 0..<(size.rows * 4) {
            let visiblePrefix = row % 5 == 0
                ? "> Ask Codex to do anything "
                : "Codex output row \(row): "
            let visibleBody = String(
                (visiblePrefix + String(repeating: "wrap-\(row)-", count: lineWidth)).prefix(lineWidth)
            )
            let styledBody = row % 5 == 0
                ? "\u{1B}[48;2;56;56;56m\(visibleBody)\u{1B}[0m"
                : "\u{1B}[38;2;166;226;46m\(visibleBody)\u{1B}[0m"
            output += styledBody + "\r\n"
        }
        output += "\u{1B}[?2026l\u{1B}[?25h"
        #expect(await view.processOutputAndWait(Data(output.utf8)))
        let before = try await observe(view, matching: try actualFrame(view, revision: 1))
        let beforeVisual = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: before.frame))
        let historyRows = try #require(before.frame.historyRows)
        #expect(historyRows > UInt64(size.rows * 2))
        #expect(beforeVisual.rows.flatMap { $0 }.contains { $0.text.contains("wrap-") })

        for _ in 0..<5 {
            view.safeAreaInsetsDidChange()
            #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
            let after = try await observe(view, matching: before.frame)
            expectRows(after.frame, equalTo: beforeVisual)
            #expect(after.frame.scrollbackRows == before.frame.scrollbackRows)
            #expect(after.frame.historyRows == before.frame.historyRows)
            #expect(after.gridGeneration == before.gridGeneration)
            #expect(after.appliedGeneration == before.appliedGeneration)
        }
    }

    @Test("render-grid capture excludes unfinished synchronized screen updates")
    func captureWaitsForSynchronizedScreenCommit() async throws {
        let mounted = try await mountSurface()
        defer { dismantle(mounted) }
        let view = mounted.view
        #expect(await view.processOutputAndWait(Data("\u{1B}[2J\u{1B}[HBASELINE".utf8)))
        #expect(try actualFrame(view, revision: 1).plainRows().first?.hasPrefix("BASELINE") == true)

        // A TUI can split one atomic redraw across several PTY reads. The
        // exporter must obey the renderer's commit boundary, even though the
        // parser has already changed the cells behind the displayed frame.
        #expect(await view.processOutputAndWait(Data(
            "\u{1B}[?2026h\u{1B}[2J\u{1B}[HPARTIAL_UNCOMMITTED".utf8
        )))
        let read = VerifiedReplaySurfaceRead(
            surface: try #require(view.surface),
            generation: view.surfaceGeneration,
            surfaceID: "synchronized-capture",
            stateSeq: 2,
            renderEpoch: "synchronized-capture",
            renderRevision: 2,
            expectedCursorColor: nil,
            configuredCursorColor: nil,
            anchor: .screen
        )
        let exported = view.outputQueue.queue.sync { read.exportGridSynchronously() }
        #expect(exported == nil)

        #expect(await view.processOutputAndWait(Data(
            "\u{1B}[2J\u{1B}[HCOMMITTED\u{1B}[?2026l".utf8
        )))
        let committed = try actualFrame(view, revision: 3)
        #expect(committed.plainRows().first?.hasPrefix("COMMITTED") == true)
        #expect(!committed.plainRows().contains { $0.contains("PARTIAL_UNCOMMITTED") })
    }

    @Test("replay verification accepts the control cells normalized by the encoder")
    func replayVerificationMatchesControlCellNormalization() async throws {
        let mounted = try await mountSurface()
        defer { dismantle(mounted) }
        let view = mounted.view
        let size = pinnedSize(inside: mounted.natural)
        #expect(await view.applyViewSizeAndWait(cols: size.columns, rows: size.rows))
        // UTF-8 C1 scalars can become cells in real output (for example,
        // double-encoded tool output). VT replay safely paints them as spaces.
        #expect(await view.processOutputAndWait(Data(
            "\u{1B}[2J\u{1B}[HC1_BEGIN \u{E2}\u{98}\u{86} C1_END".utf8
        )))
        let source = try actualFrame(view, revision: 1)
        #expect(source.rowSpans.contains { $0.text.unicodeScalars.contains("\u{86}") })
        let expected = try #require(MobileTerminalRenderGridVisualSnapshot(fullFrame: source))
        #expect(await apply(source, to: view))
        let replayed = try await observe(view, matching: source)
        expectRows(replayed.frame, equalTo: expected)
    }

    private struct MountedSurface {
        let delegate: Delegate
        let view: GhosttySurfaceView
        let window: UIWindow
        let natural: TerminalGridSize
    }

    private func mountSurface() async throws -> MountedSurface {
        let runtime = try GhosttyRuntime.shared()
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let ready = await waitUntil(timeout: .seconds(5)) {
            let snapshot = view.debugGeometrySnapshotForTesting()
            guard let rendered = snapshot.renderedSize, let reported = snapshot.reportedSize else {
                return false
            }
            return snapshot.renderRect.width > 0
                && rendered.columns == reported.columns
                && rendered.rows == reported.rows
                && rendered.columns > 32 && rendered.rows > 12
        }
        guard ready, let natural = view.debugGeometrySnapshotForTesting().renderedSize else {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
            Issue.record("The terminal did not mount with a usable natural grid")
            throw CancellationError()
        }
        view.verifiedReplayRenderSuppressed = true
        return MountedSurface(delegate: delegate, view: view, window: window, natural: natural)
    }

    private func dismantle(_ mounted: MountedSurface) {
        mounted.view.verifiedReplayRenderSuppressed = false
        mounted.view.prepareForDismantle()
        mounted.view.removeFromSuperview()
        mounted.window.isHidden = true
        withExtendedLifetime(mounted.delegate) {}
    }

    private func pinnedSize(inside natural: TerminalGridSize) -> TerminalGridSize {
        let columns = min(48, natural.columns - 8)
        let rows = min(14, natural.rows - 4)
        return TerminalGridSize(
            columns: columns,
            rows: rows,
            pixelWidth: natural.pixelWidth * columns / natural.columns,
            pixelHeight: natural.pixelHeight * rows / natural.rows
        )
    }

    private func numberedFrame(
        size: TerminalGridSize,
        theme: TerminalTheme
    ) throws -> MobileTerminalRenderGridFrame {
        let spans = (0..<size.rows).map { row in
            let prefix = String(format: "%02d ", row)
            let body = row == size.rows - 2 ? "> Ask Codex to do anything " : "Codex output: ordered row "
            let text = String((prefix + body).prefix(size.columns))
                .padding(toLength: size.columns, withPad: ".", startingAt: 0)
            return MobileTerminalRenderGridFrame.RowSpan(
                row: row, column: 0, styleID: 1 + row % 2, text: text, cellWidth: size.columns
            )
        }
        let historyCount = size.rows * 2
        let history = (0..<historyCount).map { row in
            let text = String(format: "history %02d before visible Codex rows", row)
            return MobileTerminalRenderGridFrame.RowSpan(
                row: row,
                column: 0,
                styleID: 2,
                text: String(text.prefix(size.columns)),
                cellWidth: min(text.count, size.columns)
            )
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: "geometry-primary",
            stateSeq: 1,
            renderEpoch: "geometry-epoch",
            renderRevision: 1,
            columns: size.columns,
            rows: size.rows,
            cursor: .init(row: size.rows - 2, column: 3),
            styles: [
                .init(id: 0, foreground: theme.foreground, background: theme.background),
                .init(id: 1, foreground: "#FFFFFF", background: "#383838"),
                .init(id: 2, foreground: "#A6E22E", background: "#202020")
            ],
            rowSpans: spans,
            terminalConfigTheme: theme,
            scrollbackRows: historyCount,
            scrollbackSpans: history,
            anchor: .screen,
            historyRows: UInt64(historyCount)
        )
    }

    private func typedDelta(
        for frame: MobileTerminalRenderGridFrame
    ) throws -> MobileTerminalRenderGridFrame {
        let row = frame.rows - 2
        let text = String("> DELTA typed without replay".prefix(frame.columns)).padding(
            toLength: frame.columns, withPad: ".", startingAt: 0
        )
        return try MobileTerminalRenderGridFrame(
            surfaceID: frame.surfaceID,
            stateSeq: frame.stateSeq + 1,
            renderEpoch: frame.renderEpoch,
            renderRevision: frame.renderRevision + 1,
            columns: frame.columns,
            rows: frame.rows,
            cursor: .init(row: row, column: min(text.count - 1, frame.columns - 1)),
            full: false,
            clearedRows: [row],
            styles: frame.styles,
            rowSpans: [.init(row: row, column: 0, styleID: 2, text: text, cellWidth: frame.columns)],
            anchor: .screen,
            historyRows: frame.historyRows,
            deltaBaseHistoryRows: frame.historyRows,
            deltaBaseRenderRevision: frame.renderRevision
        )
    }

    private func actualFrame(
        _ view: GhosttySurfaceView,
        revision: UInt64
    ) throws -> MobileTerminalRenderGridFrame {
        let read = VerifiedReplaySurfaceRead(
            surface: try #require(view.surface),
            generation: view.surfaceGeneration,
            surfaceID: "geometry-raw-vt",
            stateSeq: revision,
            renderEpoch: "geometry-raw-vt-epoch",
            renderRevision: revision,
            expectedCursorColor: nil,
            configuredCursorColor: nil,
            anchor: .screen
        )
        let queue = view.outputQueue
        let exported: MobileTerminalRenderGridFrame? = queue.queue.sync {
            read.exportGridSynchronously()
        }
        return try #require(exported)
    }

    private func apply(_ frame: MobileTerminalRenderGridFrame, to view: GhosttySurfaceView) async -> Bool {
        await view.processOutputAndWait(
            frame.full ? frame.vtReplacementBytes() : frame.vtPatchBytes(),
            terminalConfigTheme: frame.terminalConfigTheme,
            renderGridContract: RenderGridApplyContract(
                columns: frame.columns,
                rows: frame.rows,
                isDelta: !frame.full,
                requiresSurfaceDimensionCheck: frame.full
            )
        )
    }

    private func observe(
        _ view: GhosttySurfaceView,
        matching frame: MobileTerminalRenderGridFrame
    ) async throws -> GeometryGridObservation {
        let read = VerifiedReplaySurfaceRead(
            surface: try #require(view.surface),
            generation: view.surfaceGeneration,
            surfaceID: frame.surfaceID,
            stateSeq: frame.stateSeq,
            renderEpoch: frame.renderEpoch,
            renderRevision: frame.renderRevision,
            expectedCursorColor: nil,
            configuredCursorColor: nil,
            anchor: .screen
        )
        let queue = view.outputQueue
        let observation: GeometryGridObservation? = await withCheckedContinuation { continuation in
            let accepted = queue.async {
                guard let exported = read.exportGridSynchronously() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: GeometryGridObservation(
                    frame: exported,
                    gridGeneration: queue.observedGridGeneration,
                    appliedGeneration: queue.gridGenerationAtLastRenderGridApply
                ))
            }
            if !accepted { continuation.resume(returning: nil) }
        }
        return try #require(observation)
    }

    private func expectRows(
        _ frame: MobileTerminalRenderGridFrame,
        equalTo expected: MobileTerminalRenderGridVisualSnapshot
    ) {
        let observed = MobileTerminalRenderGridVisualSnapshot(fullFrame: frame)
        #expect(observed?.columns == expected.columns)
        #expect(observed?.rowCount == expected.rowCount)
        #expect(observed?.activeScreen == .primary)
        #expect(observed?.defaultStyle == expected.defaultStyle)
        #expect(observed?.rows == expected.rows)
    }

    private func growViewportByOneColumn(
        view: GhosttySurfaceView,
        window: UIWindow,
        snapshot: GhosttySurfaceView.DebugGeometrySnapshot,
        columns: Int
    ) {
        let cellWidth = snapshot.renderRect.width / CGFloat(columns)
        window.frame.size.width += cellWidth + 1
        view.frame = window.bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func waitUntil(
        timeout: Duration,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate() { return true }
            do {
                try await clock.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return predicate()
    }
}

private struct GeometryGridObservation: Sendable {
    let frame: MobileTerminalRenderGridFrame
    let gridGeneration: UInt64
    let appliedGeneration: UInt64?
}
#endif
