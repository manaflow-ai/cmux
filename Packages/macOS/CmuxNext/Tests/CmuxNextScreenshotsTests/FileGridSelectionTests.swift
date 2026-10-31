import AppKit
import Carbon.HIToolbox
@testable import CmuxNextFileGrid
import CmuxNextTestSupport
import Foundation
import Testing

/// The selection rules of the Screenshots grid (cmux://screenshots), as in Finder and Photos:
/// Lawrence 2026-10-23, "make shift click and cmd click in cmux://screenshots work".
@Suite(.closesItsWindows) struct FileGridSelectionTests {
    @Test func aPlainClickSelectsOneTileAndAnchorsIt() {
        let selection = FileGridSelection(indices: [0, 1, 4], anchor: 1).clicking(3, .select)
        #expect(selection.indices == [3])
        #expect(selection.anchor == 3)
    }

    @Test func cmdClickAddsAndRemovesOneTile() {
        var selection = FileGridSelection().clicking(1, .select)
        selection = selection.clicking(4, .toggle)
        #expect(selection.indices == [1, 4])
        #expect(selection.anchor == 4)
        selection = selection.clicking(1, .toggle)
        #expect(selection.indices == [4])
        #expect(selection.anchor == 1, "a Cmd-click that removes a tile still moves the anchor, as in Finder")
    }

    @Test func shiftClickSelectsTheRunFromTheAnchorInEitherDirection() {
        var selection = FileGridSelection().clicking(2, .select).clicking(5, .range)
        #expect(selection.indices == [2, 3, 4, 5])
        #expect(selection.anchor == 2, "Shift-click keeps the anchor")
        selection = selection.clicking(0, .range)
        #expect(selection.indices == [0, 1, 2], "a second Shift-click replaces the run, not adds to it")
    }

    @Test func shiftClickAfterCmdClickRunsFromTheCmdClickedTile() {
        let selection = FileGridSelection().clicking(0, .select).clicking(6, .toggle).clicking(8, .range)
        #expect(selection.indices == [6, 7, 8])
    }

    @Test func shiftCmdClickAddsTheRunToTheSelection() {
        let selection = FileGridSelection().clicking(0, .select).clicking(5, .toggle).clicking(7, .addRange)
        #expect(selection.indices == [0, 5, 6, 7])
        #expect(selection.anchor == 5)
    }

    @Test func shiftClickWithoutAnAnchorActsAsAClick() {
        #expect(FileGridSelection().clicking(3, .range) == FileGridSelection(indices: [3], anchor: 3))
        #expect(FileGridSelection(indices: [1]).clicking(3, .addRange) == FileGridSelection(indices: [1, 3], anchor: 3))
    }

    @Test func selectAllAndClear() {
        let all = FileGridSelection().clicking(2, .select).selectingAll(count: 4)
        #expect(all.indices == [0, 1, 2, 3])
        #expect(all.anchor == 2)
        #expect(all.cleared() == FileGridSelection())
        #expect(FileGridSelection(anchor: 9).selectingAll(count: 3).anchor == nil, "an anchor past the end is dropped")
    }

    @Test(arguments: [
        (NSEvent.ModifierFlags(), FileGridClickKind.select),
        ([.command], .toggle),
        ([.shift], .range),
        ([.shift, .command], .addRange),
        ([.option], .select),
        ([.command, .capsLock], .toggle),
    ] as [(NSEvent.ModifierFlags, FileGridClickKind)])
    func modifierKeysPickTheClickKind(flags: NSEvent.ModifierFlags, kind: FileGridClickKind) {
        #expect(FileGridClickKind(modifiers: flags) == kind)
    }
}

/// The same rules through the real grid: mouse and key events sent to its collection view
/// (AppKit's press tracking off: a ci-step Mac has no window server session to track in).
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(1))) struct FileGridClickTests {
    private static let names = (0..<8).map { "shot-\($0).png" }

    private func grid() -> (FileGridView, NSWindow) {
        _ = NSApplication.shared
        let grid = FileGridView(cache: ThumbnailCache(capacity: 16, generator: CountingGenerator()),
                                appearance: FileGridAppearance(tileSide: 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        // The test owns the window; closing must not also release it.
        window.isReleasedWhenClosed = false
        grid.frame = window.contentView!.bounds
        window.contentView!.addSubview(grid)
        grid.show(Self.names.map { name in
            FileGridItem(url: URL(fileURLWithPath: "/shots/\(name)"), size: 1, modified: Date(timeIntervalSinceReferenceDate: 1), sourceID: "s")
        })
        grid.collectionView.tracksPresses = false
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        return (grid, window)
    }

    private func close(_ window: NSWindow) { window.close() }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, _ flags: NSEvent.ModifierFlags, _ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Clicks tile `index` with `flags`.
    private func click(_ index: Int, _ flags: NSEvent.ModifierFlags = [], _ grid: FileGridView, _ window: NSWindow) {
        let collection = grid.collectionView
        let frame = collection.frameForItem(at: index)
        let point = collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        collection.mouseDown(with: mouse(.leftMouseDown, at: point, flags, window))
    }

    private func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags, _ grid: FileGridView, _ window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: characters,
                                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
        grid.collectionView.keyDown(with: event)
    }

    private func selected(_ grid: FileGridView) -> [String] { grid.selectedItems.map(\.name) }

    @Test func cmdClickTogglesTilesInAndOut() {
        let (grid, window) = grid()
        defer { close(window) }
        click(1, [], grid, window)
        #expect(selected(grid) == ["shot-1.png"])
        click(4, [.command], grid, window)
        click(6, [.command], grid, window)
        #expect(selected(grid) == ["shot-1.png", "shot-4.png", "shot-6.png"])
        click(4, [.command], grid, window)
        #expect(selected(grid) == ["shot-1.png", "shot-6.png"])
    }

    @Test func shiftClickSelectsTheRunFromTheLastClick() {
        let (grid, window) = grid()
        defer { close(window) }
        click(2, [], grid, window)
        click(5, [.shift], grid, window)
        #expect(selected(grid) == ["shot-2.png", "shot-3.png", "shot-4.png", "shot-5.png"])
        click(0, [.shift], grid, window)
        #expect(selected(grid) == ["shot-0.png", "shot-1.png", "shot-2.png"])
    }

    @Test func shiftCmdClickAddsARunAndAPlainClickCollapses() {
        let (grid, window) = grid()
        defer { close(window) }
        click(0, [], grid, window)
        click(4, [.command], grid, window)
        click(6, [.shift, .command], grid, window)
        #expect(selected(grid) == ["shot-0.png", "shot-4.png", "shot-5.png", "shot-6.png"])
        click(5, [], grid, window)
        #expect(selected(grid) == ["shot-5.png"], "a plain click on a selected tile, released without a drag, selects it alone")
    }

    @Test func cmdASelectsEveryTileAndEscClears() {
        let (grid, window) = grid()
        defer { close(window) }
        key(kVK_ANSI_A, "a", [.command], grid, window)
        #expect(selected(grid) == Self.names)
        key(kVK_Escape, "\u{1b}", [], grid, window)
        #expect(selected(grid).isEmpty)
    }

    @Test func commandsRunOnTheWholeSelection() {
        let (grid, window) = grid()
        defer { close(window) }
        var ran: [(FileGridCommand, [String])] = []
        grid.onCommand = { command, items in ran.append((command, items.map(\.name))) }
        click(1, [], grid, window)
        click(3, [.shift], grid, window)
        click(7, [.command], grid, window)
        key(kVK_ANSI_O, "o", [.command], grid, window)
        #expect(ran.first?.0 == .open)
        #expect(ran.first?.1 == ["shot-1.png", "shot-2.png", "shot-3.png", "shot-7.png"])
    }
}
