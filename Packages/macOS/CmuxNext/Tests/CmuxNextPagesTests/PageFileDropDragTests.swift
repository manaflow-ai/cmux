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
        // The drag ends: WebKit has no `draggingEnded:`, so the end must not forward it (it threw
        // "unrecognized selector" and ended the app). The end drops the answer, so a move reads again.
        web.draggingEnded(second)
        _ = web.draggingUpdated(second)
        #expect(reads == 3)
    }

    /// Files dropped on the page itself reach `onFilesDropped` with every file URL of the drag, so
    /// the agent page can send a local chat's files as their paths (AgentPaneDroppedPaths).
    @Test func aPageDropPassesTheDraggedFileURLs() {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        let urls = [URL(fileURLWithPath: "/tmp/cmux-drop/docs", isDirectory: true), URL(fileURLWithPath: "/tmp/cmux-drop/build.zip")]
        web.readDroppedFileURLs = { _ in urls }
        var dropped: [[URL]] = []
        web.onFilesDropped = { dropped.append($0) }
        _ = web.performDragOperation(Drag(sequence: 3))
        #expect(dropped == [urls])
    }

    /// A drop the host opens itself (``PageFileDrop``) is not the page's: `onFilesDropped` never runs.
    @Test func aDropTheHostOpensPassesNoURLs() {
        let web = page(reads: {})
        web.readDroppedFileURLs = { _ in [URL(fileURLWithPath: "/tmp/cmux-drop/build.zip")] }
        var dropped: [[URL]] = []
        web.onFilesDropped = { dropped.append($0) }
        _ = web.draggingEntered(Drag(sequence: 4))
        #expect(web.performDragOperation(Drag(sequence: 4)))
        #expect(dropped.isEmpty)
    }

    /// A paste (Cmd-V, Edit > Paste, the composer's menu) tells the host first, then WebKit pastes.
    @Test func aPasteTellsTheHostFirst() {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        var pastes = 0
        web.onPaste = { pastes += 1 }
        _ = web.perform(#selector(NSText.paste(_:)), with: nil)
        #expect(pastes == 1)
    }
}
