import AppKit
@testable import CmuxNextPages
import Testing

/// DRAG-LAG (u2426): AppKit waits for each `draggingUpdated` answer, so a pasteboard read on every
/// drag move (a round trip to the pasteboard server) makes a drag over a page lag. The page's web
/// view reads the drag's file once when the drag enters and keeps that answer until the drag ends.
@MainActor
struct PageFileDropDragTests {
    @MainActor final class Drag: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.page-drop-test.\(UUID().uuidString)"))
        let draggingSequenceNumber: Int
        init(sequence: Int) { draggingSequenceNumber = sequence }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { NSPoint(x: 50, y: 50) }
        var draggedImageLocation: NSPoint { NSPoint(x: 50, y: 50) }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private let file = URL(fileURLWithPath: "/tmp/cmux-page-drop-test.png")

    private func page(reads: @escaping @MainActor () -> Void, opened: @escaping @MainActor (URL) -> Void = { _ in }) -> PageWKWebView {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        let file = file
        web.readDroppedFileURL = { _ in reads(); return file }
        web.fileDrop = PageFileDrop(accepts: { $0.isFileURL }, open: opened)
        return web
    }

    /// 240 drag moves read the pasteboard once, and every move still answers copy.
    @Test func dragMovesReadThePasteboardOnce() {
        var reads = 0
        let web = page(reads: { reads += 1 })
        let drag = Drag(sequence: 7)
        #expect(web.draggingEntered(drag) == .copy)
        for _ in 0..<240 { #expect(web.draggingUpdated(drag) == .copy) }
        #expect(reads == 1)
    }

    /// The drop opens the file from the cached answer; a new drag reads again.
    @Test func dropUsesTheAnswerAndANewDragReadsAgain() {
        var reads = 0
        var opened: [URL] = []
        let web = page(reads: { reads += 1 }, opened: { opened.append($0) })
        let first = Drag(sequence: 1)
        _ = web.draggingEntered(first)
        for _ in 0..<10 { _ = web.draggingUpdated(first) }
        #expect(web.performDragOperation(first))
        #expect(opened == [file])
        #expect(reads == 1)
        let second = Drag(sequence: 2)
        _ = web.draggingEntered(second)
        _ = web.draggingUpdated(second)
        #expect(reads == 2)
    }
}
