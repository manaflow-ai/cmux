// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import CmuxTerminalAccess

/// Behavior-level invariants for ``SnapshotPoller`` (D8) that complement
/// the basic emit/suppress coverage in ``SnapshotPollerTests``.
///
/// These tests probe four orthogonal corners the Phase 2 cells stream
/// relies on:
///
/// 1. **Cursor-only change emits.** Moving the cursor without touching
///    any glyph still changes the digest, so the poller must emit.
/// 2. **Off-digest attribute change is suppressed.** ``CellGridDigest``
///    intentionally hashes only codepoints + cursor + grid shape; SGR
///    attrs/colors/underline/hyperlink are NOT in the digest. A change
///    to those fields alone must NOT trigger an emit (collision-free
///    case from the digest's perspective).
/// 3. **read errors don't crash the poller.** ``SnapshotPoller/tick()``
///    propagates the error to the caller; subsequent ticks recover.
/// 4. **stop() prevents future emits via tick().** Even though tick()
///    runs unconditionally in tests, the polling loop in start() honors
///    the running flag, so an explicit stop() is observable through
///    ``shouldKeepRunning()``.
@Suite struct SnapshotPollerInvariantsTests {
    /// Constructs a 1x1 grid with overridable cursor position + first
    /// cell attributes (SGR set). The default grid letter is "a" with
    /// cursor at (0, 0) and no attrs.
    private static func makeGrid(
        letter: String = "a",
        cursorRow: Int = 0,
        cursorCol: Int = 0,
        attrs: Set<CellAttribute> = []
    ) -> CellGrid {
        let cell = Cell(
            t: letter, wide: .narrow, fg: .default, bg: .default,
            attrs: attrs, underlineKind: nil, underlineColor: nil,
            hyperlink: nil, semantic: nil
        )
        return CellGrid(
            cols: 1, rows: 1, altScreen: false, title: nil,
            cursor: CursorState(row: cursorRow, col: cursorCol, visible: true, style: .block),
            semanticAvailable: false,
            rowsData: [CellRow(wrap: false, wrapContinuation: false, cells: [cell])]
        )
    }

    /// Cursor move alone (identical text) still flips the digest and
    /// must emit. Uses a 2x1 grid so cursor.col can change without
    /// resizing the grid.
    @Test func emitsOnCursorOnlyChange() async throws {
        let state = GridBox()
        await state.set(
            CellGrid(
                cols: 2, rows: 1, altScreen: false, title: nil,
                cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
                semanticAvailable: false,
                rowsData: [
                    CellRow(wrap: false, wrapContinuation: false, cells: [
                        Cell(t: "a", wide: .narrow, fg: .default, bg: .default, attrs: []),
                        Cell(t: "b", wide: .narrow, fg: .default, bg: .default, attrs: [])
                    ])
                ]
            )
        )
        let counter = Counter()
        let poller = SnapshotPoller(
            interval: 0.1, clock: ManualClock(),
            read: { await state.value },
            emit: { _ in await counter.bump() }
        )
        try await poller.tick()
        // Move cursor only; text unchanged.
        await state.mutateCursor(col: 1)
        try await poller.tick()
        let n = await counter.value
        #expect(n == 2, "cursor move on identical text must produce a fresh emit")
    }

    /// Changing only fields that ``CellGridDigest`` does NOT hash (cell
    /// attrs/colors/underline) MUST be suppressed. This pins the digest
    /// contract: tests against the contract, not the implementation.
    @Test func suppressesEmitWhenOnlyOffDigestAttrsChange() async throws {
        let state = GridBox()
        await state.set(Self.makeGrid(letter: "a", attrs: []))
        let counter = Counter()
        let poller = SnapshotPoller(
            interval: 0.1, clock: ManualClock(),
            read: { await state.value },
            emit: { _ in await counter.bump() }
        )
        try await poller.tick()
        // Same text + same cursor, only SGR attrs differ.
        await state.set(Self.makeGrid(letter: "a", attrs: [.bold]))
        try await poller.tick()
        await state.set(Self.makeGrid(letter: "a", attrs: [.bold, .italic]))
        try await poller.tick()
        let n = await counter.value
        #expect(n == 1, "off-digest attr changes must NOT emit (D8 digest contract)")
    }

    /// A throwing read on tick() surfaces the error but does not crash
    /// the actor or corrupt state — the next successful tick still
    /// emits exactly once.
    @Test func readErrorDoesNotCrashPollerAndRecoversOnNextTick() async throws {
        let toggle = ErrorToggle()
        let counter = Counter()
        let poller = SnapshotPoller(
            interval: 0.1, clock: ManualClock(),
            read: {
                if await toggle.shouldThrow {
                    throw TerminalAccessError.unsupported(reason: "fake-read-error")
                }
                return Self.makeGrid(letter: "a")
            },
            emit: { _ in await counter.bump() }
        )
        await toggle.set(true)
        // First tick — read throws; poller must propagate but not crash.
        do {
            try await poller.tick()
            Issue.record("expected throwing read to propagate from tick()")
        } catch {
            // expected
        }
        // Recover on next tick.
        await toggle.set(false)
        try await poller.tick()
        let n = await counter.value
        #expect(n == 1)
        // Another successful tick with identical data must still suppress.
        try await poller.tick()
        let n2 = await counter.value
        #expect(n2 == 1)
    }

    /// stop() flips the running flag observable via shouldKeepRunning();
    /// the production polling loop in start() honors this and ceases
    /// to call tick(). This pins the lifecycle contract without timing-
    /// sensitive sleeps.
    @Test func stopFlipsShouldKeepRunningFlag() async throws {
        let poller = SnapshotPoller(
            interval: 0.1, clock: ManualClock(),
            read: { Self.makeGrid() },
            emit: { _ in }
        )
        await poller.start()
        let runningBefore = await poller.shouldKeepRunning()
        #expect(runningBefore)
        await poller.stop()
        let runningAfter = await poller.shouldKeepRunning()
        #expect(!runningAfter)
    }
}

private actor GridBox {
    private(set) var value: CellGrid = CellGrid(
        cols: 1, rows: 1, altScreen: false, title: nil,
        cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
        semanticAvailable: false, rowsData: []
    )
    func set(_ g: CellGrid) { value = g }
    func mutateCursor(col: Int) {
        value = CellGrid(
            cols: value.cols, rows: value.rows, altScreen: value.altScreen,
            title: value.title,
            cursor: CursorState(row: value.cursor.row, col: col,
                                visible: value.cursor.visible, style: value.cursor.style),
            semanticAvailable: value.semanticAvailable,
            rowsData: value.rowsData
        )
    }
}

private actor Counter {
    var value: Int = 0
    func bump() { value += 1 }
}

private actor ErrorToggle {
    var shouldThrow: Bool = false
    func set(_ v: Bool) { shouldThrow = v }
}
