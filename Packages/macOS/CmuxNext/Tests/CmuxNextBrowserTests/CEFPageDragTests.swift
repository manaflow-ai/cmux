import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import UniformTypeIdentifiers

/// Task 051 of plans/cmux-next/chrome-parity/p01-process.md: a hosted page's drag reaches cmux as the fork's
/// `cmux_drag_source_t` (read at the offsets ChromiumHost/src/host_drag.h asserts), becomes one pasteboard
/// writer (the link with its title and as text, the text, the HTML, a dragged image as a file promise that
/// carries the rest too), and the page view starts the session at the pointer; a drag that cannot show ends at
/// once with no operation. Back over its page the drag goes through task 050's drag destination, entered with
/// `drag_target_enter_source` and answered by the page: where the page takes none, AppKit is refused and the
/// session ends with none. The session itself (a link or an image to Finder and a terminal) is
/// chromium-host-bench.py's dragout row on the fleet.
@MainActor
@Suite(.serialized) struct CEFPageDragTests {
    /// A fork struct in C layout over storage the closure may read.
    // SAFETY (every `unsafe` here): the struct is allocated, zeroed and written at the fork's LP64 offsets
    // (CEFPageDragData.Offset) before `body` reads it; its strings and byte buffers outlive the call.
    func withForkDrag<T>(size: Int32 = Int32(CEFPageDragData.Offset.size), url: String = "https://example.com/cat.png",
                         title: String = "A cat", text: String = "", html: String = "", file: [UInt8] = [], image: [UInt8] = [],
                         scale: Double = 2, offset: (Int32, Int32) = (12, 7), _ body: (UnsafeRawPointer) throws -> T) rethrows -> T {
        typealias O = CEFPageDragData.Offset
        let raw = unsafe UnsafeMutableRawPointer.allocate(byteCount: O.size, alignment: 8)
        unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: O.size)
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer {
            unsafe owned.forEach { unsafe free($0) }
            unsafe raw.deallocate()
        }
        func put(_ text: String, at offset: Int) {
            guard let copy = unsafe strdup(text) else { return }
            unsafe owned.append(copy)
            unsafe raw.storeBytes(of: UnsafePointer(copy), toByteOffset: offset, as: UnsafePointer<CChar>?.self)
        }
        unsafe raw.storeBytes(of: size, toByteOffset: 0, as: Int32.self)
        unsafe raw.storeBytes(of: 1 | 2 | 16 | 4, toByteOffset: O.allowedOperations, as: Int32.self)
        put(url, at: O.url)
        put(title, at: O.urlTitle)
        put(text, at: O.text)
        put(html, at: O.html)
        put("https://example.com/", at: O.htmlBaseUrl)
        put("cat.png", at: O.fileName)
        put(url, at: O.fileContentsSourceUrl)
        put("", at: O.downloadMetadata)
        return try unsafe file.withUnsafeBytes { fileBytes in
            try unsafe image.withUnsafeBytes { imageBytes in
                unsafe raw.storeBytes(of: file.isEmpty ? nil : fileBytes.baseAddress, toByteOffset: O.fileContents,
                                      as: UnsafeRawPointer?.self)
                unsafe raw.storeBytes(of: Int32(file.count), toByteOffset: O.fileContentsLength, as: Int32.self)
                unsafe raw.storeBytes(of: image.isEmpty ? nil : imageBytes.baseAddress, toByteOffset: O.imagePng,
                                      as: UnsafeRawPointer?.self)
                unsafe raw.storeBytes(of: Int32(image.count), toByteOffset: O.imagePngLength, as: Int32.self)
                unsafe raw.storeBytes(of: scale, toByteOffset: O.imageScale, as: Double.self)
                unsafe raw.storeBytes(of: offset.0, toByteOffset: O.cursorOffsetX, as: Int32.self)
                unsafe raw.storeBytes(of: offset.1, toByteOffset: O.cursorOffsetY, as: Int32.self)
                return try unsafe body(UnsafeRawPointer(raw))
            }
        }
    }

    /// A `width` x `height` pixel PNG.
    func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func readsTheForkStruct() throws {
        let drag = try #require(unsafe withForkDrag(html: "<img>", file: [0x89, 0, 1], image: [7, 8]) { unsafe CEFPageDragData(fork: $0) })
        #expect(drag.allowedOperations == [.copy, .link, .move], "generic (4) is not a page operation")
        #expect(drag.url == "https://example.com/cat.png" && drag.urlTitle == "A cat" && drag.text.isEmpty)
        #expect(drag.html == "<img>" && drag.htmlBaseURL == "https://example.com/")
        #expect(drag.fileContents == Data([0x89, 0, 1]) && drag.fileName == "cat.png")
        #expect(drag.imagePNG == Data([7, 8]) && drag.imageScale == 2 && drag.cursorOffset == CGPoint(x: 12, y: 7))

        #expect(unsafe withForkDrag(size: Int32(CEFPageDragData.Offset.size) - 8) { unsafe CEFPageDragData(fork: $0) } == nil,
                "a struct older than API 30's is refused")
        let unscaled = try #require(unsafe withForkDrag(scale: 0) { unsafe CEFPageDragData(fork: $0) })
        #expect(unscaled.imageScale == 1 && unscaled.fileContents.isEmpty && unscaled.imagePNG.isEmpty)
    }

    @Test func aLinkIsItsURLItsTitleAndItsText() {
        let marker = ChromiumHostPageView.pageDragType
        let link = CEFPageDragData(allowedOperations: [.copy, .link], url: "https://example.com/a", urlTitle: "A page")
        let strings = link.strings(marker: marker)
        #expect(strings[.URL] == "https://example.com/a")
        #expect(strings[.string] == "https://example.com/a", "a terminal or a text field gets the URL")
        #expect(strings[NSPasteboard.PasteboardType("public.url-name")] == "A page", "Finder names the .webloc")
        #expect(strings[marker] == "1")
        let item = link.pasteboardWriter(marker: marker) as? NSPasteboardItem
        #expect(item?.string(forType: .URL) == "https://example.com/a")
        #expect(Set(item?.types ?? []) == Set(strings.keys))

        let selection = CEFPageDragData(allowedOperations: .copy, url: "not a url", text: "hello", html: "<b>hello</b>")
        let text = selection.strings(marker: marker)
        #expect(text[.string] == "hello" && text[.html] == "<b>hello</b>" && text[.URL] == nil)
    }

    @Test func anImageIsAFilePromiseThatCarriesItsURL() throws {
        let marker = ChromiumHostPageView.pageDragType
        let image = CEFPageDragData(allowedOperations: .copy, url: "https://example.com/img/cat.png?size=2", urlTitle: "",
                                    fileContents: Data([1, 2, 3]), fileName: "", fileSourceURL: "https://example.com/img/cat.png")
        #expect(image.promisedFileName == "cat.png")
        #expect(image.promisedFileType == .png)
        let promise = try #require(image.pasteboardWriter(marker: marker) as? CEFPageDragFilePromise)
        #expect(promise.fileType == UTType.png.identifier)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux-page-drag-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let types = promise.writableTypes(for: pasteboard)
        #expect(types.contains(.URL) && types.contains(.string) && types.contains(marker))
        #expect(promise.pasteboardPropertyList(forType: .URL) as? String == "https://example.com/img/cat.png?size=2")
        #expect(CEFPageDragData(allowedOperations: .copy, fileContents: Data([1]), fileName: "../").promisedFileName == "download")
    }

    @Test func thePromisedFileIsWrittenOffTheMainThread() async throws {
        let writer = CEFPageDragFileWriter(contents: Data([4, 5, 6]), name: "cat.png")
        let promise = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)
        #expect(writer.filePromiseProvider(promise, fileNameForType: UTType.png.identifier) == "cat.png")
        let queue = writer.operationQueue(for: promise)
        #expect(queue !== OperationQueue.main)
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-page-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "cat.png")
        // On the queue the writer names, as AppKit calls it; nothing else touches the two meanwhile.
        nonisolated(unsafe) let queuedWriter = writer
        nonisolated(unsafe) let queuedPromise = promise
        let failure: (any Error)? = await withCheckedContinuation { done in
            queue.addOperation {
                queuedWriter.filePromiseProvider(queuedPromise, writePromiseTo: target) { done.resume(returning: $0) }
            }
        }
        #expect(failure == nil)
        #expect(try Data(contentsOf: target) == Data([4, 5, 6]))
    }

    @Test func theImageSitsUnderThePointerAtItsOffset() throws {
        let data = CEFPageDragData(allowedOperations: .copy, imagePNG: try png(width: 80, height: 40), imageScale: 2,
                                   cursorOffset: CGPoint(x: 10, y: 5))
        let image = try #require(ChromiumHostPageView.dragImage(data))
        #expect(image.size == NSSize(width: 40, height: 20), "pixels / scale")
        // Unflipped view: the pointer at (100, 300) is 10 points right of the image's left and 5 below its top.
        #expect(ChromiumHostPageView.draggingFrame(image: image.size, offset: data.cursorOffset, pointer: CGPoint(x: 100, y: 300))
                    == CGRect(x: 90, y: 285, width: 40, height: 20))
        #expect(ChromiumHostPageView.dragImage(CEFPageDragData(allowedOperations: .copy)) == nil)
    }

    @Test func theOfferedOperationIsTheFirstThePageAllows() {
        #expect(CEFPageDragData(allowedOperations: [.copy, .link, .move]).preferredOperation == .copy)
        #expect(CEFPageDragData(allowedOperations: [.link, .move]).preferredOperation == .link)
        #expect(CEFPageDragData(allowedOperations: .move).preferredOperation == .move, "a sortable list's move-only drag")
        #expect(CEFPageDragData(allowedOperations: []).preferredOperation == [])
    }

    @Test func aDragThatCannotShowEndsAtOnceWithNoOperation() throws {
        PageDragSpy.reset()
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-page-drag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = CEFRuntime(shim: try CEFShimLibrary.resolving(PageDragSpy.symbol), storage: CEFProfileStorage(root: root))
        runtime.pageDragStarted(CEFPageDragData(allowedOperations: .copy, url: "https://example.com/"), browser: 41)
        runtime.pageDragStarted(nil, browser: 42)
        #expect(PageDragSpy.ended.map(\.browser) == [41, 42], "no tab shows 41; 42's struct did not read")
        #expect(PageDragSpy.ended.allSatisfy { $0.operation == 0 })

        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let ended = runtime.pageDragEnded(browser: 41)
        #expect(!page.beginPageDrag(CEFPageDragData(allowedOperations: .copy), browser: 41, ended: ended),
                "a view in no window starts nothing")
        #expect(page.pageDrag == nil && page.dragCounts.sessions == 0)
        ended(CGPoint(x: 5, y: 6), CGPoint(x: 7, y: 8), .copy)
        #expect(PageDragSpy.ended.last.map { $0.browser == 41 && $0.operation == 1 } == true)
    }

    /// Back over its page the drag enters with its own data and then takes the page's answers, as task 050's drags do.
    @Test func theOwnDragEntersAsTheSourceAndOffersThePagesAnswer() {
        let wire = OwnDragWire(browser: 41)
        let destination = ChromiumHostDragDestination()
        destination.wire = wire
        let at = ChromiumHostDragPoint(x: 20, y: 30)
        #expect(destination.enteredSource(browser: 41, at: at, allowed: [.copy, .move], initial: .copy, modifiers: 1 << 4) == .copy,
                "the page's preferred operation until it answers")
        #expect(wire.sent == [.enterSource(at, allowed: 1 | 16, modifiers: 1 << 4)])
        destination.answered(browser: 41, operation: 16)
        #expect(destination.updated(at: at, allowed: [.copy, .move], modifiers: 1 << 4) == .move, "a sortable list takes a move")
        #expect(destination.dropped(at: at, modifiers: 0))
        #expect(wire.sent.last == .drop(at, modifiers: 0))
        #expect(destination.counts.enters == 1 && destination.counts.drops == 1 && destination.counts.answers == 1)
    }

    /// Where the page takes none (no dragover handler cancels it), AppKit is refused: the session ends with no
    /// operation, so drag_source_ended reports none and the page's dragend sees dropEffect "none".
    @Test func aRefusedAnswerRefusesTheDropAndTheDragLeaves() {
        let wire = OwnDragWire(browser: 41)
        let destination = ChromiumHostDragDestination()
        destination.wire = wire
        let at = ChromiumHostDragPoint(x: 20, y: 30)
        _ = destination.enteredSource(browser: 41, at: at, allowed: .copy, initial: .copy, modifiers: 0)
        destination.answered(browser: 41, operation: 0)
        #expect(destination.updated(at: at, allowed: .copy, modifiers: 0) == [], "no copy cursor where the page refuses")

        // AppKit may still drop when the refusal came after its last update: the drop is refused there too.
        #expect(!destination.dropped(at: at, modifiers: 0))
        #expect(wire.sent.last == .leave, "the page hears its drag leave, not a drop")
        #expect(!wire.sent.contains(.drop(at, modifiers: 0)))
        #expect(destination.counts.drops == 0 && destination.browser == nil)
    }

    @Test func theOwnDragIsRefusedOverAnotherTabAndOutsideDragsWhenOnlyDragOutIsOn() {
        let wire = OwnDragWire(browser: 42)
        let destination = ChromiumHostDragDestination()
        destination.wire = wire
        destination.takesOutsideDrags = false
        let at = ChromiumHostDragPoint(x: 1, y: 2)
        #expect(destination.enteredSource(browser: 41, at: at, allowed: .copy, initial: .copy, modifiers: 0) == [],
                "the view shows another tab now: the drag is not over its own page")
        #expect(destination.entered(ChromiumHostDropData(text: "t"), at: at, allowed: .copy, modifiers: 0) == [],
                "feature chromiumHostDragIn is off")
        #expect(wire.sent.isEmpty)
        #expect(destination.enteredSource(browser: 42, at: at, allowed: .copy, initial: .copy, modifiers: 0) == .copy)

        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), inputTarget: .view)
        page.takeDrags(through: wire, outside: false)
        #expect(page.registeredDraggedTypes == [ChromiumHostPageView.pageDragType], "only the page's own drag")
    }

    /// The shim's DragTarget ops send the own drag's enter as `cmux_shim_browser_drag_target_enter_source`.
    @Test func theShimSendsTheEnterSource() throws {
        PageDragSpy.reset()
        let shim = try CEFShimLibrary.resolving(PageDragSpy.symbol)
        shim.dragTarget.send(.enterSource(ChromiumHostDragPoint(x: 3, y: 4), allowed: 17, modifiers: 16), browser: 41)
        #expect(PageDragSpy.entered == ["41 3,4 17 16"])
    }
}

/// Records the destination's calls; the view shows `browser`.
private final class OwnDragWire: ChromiumHostDragWire {
    let dragBrowser: Int32?
    var sent: [ChromiumHostDragEvent] = []

    init(browser: Int32) {
        dragBrowser = browser
    }

    func send(_ event: ChromiumHostDragEvent, browser: Int32) {
        sent.append(event)
    }
}

/// Records the drag calls; every other export does nothing.
private nonisolated enum PageDragSpy {
    nonisolated(unsafe) static var ended: [(browser: Int32, operation: Int32)] = []
    nonisolated(unsafe) static var entered: [String] = []

    static func reset() {
        ended = []
        entered = []
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let ended: @convention(c) (Int32, Double, Double, Double, Double, Int32) -> Int32 = { browser, _, _, _, _, operation in
            PageDragSpy.ended.append((browser, operation))
            return 1
        }
        let entered: @convention(c) (Int32, Int32, Int32, Int32, Int32) -> Int32 = { browser, x, y, allowed, modifiers in
            PageDragSpy.entered.append("\(browser) \(x),\(y) \(allowed) \(modifiers)")
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return switch name {
        case "cmux_shim_browser_drag_source_ended": unsafeBitCast(ended, to: UnsafeMutableRawPointer.self)
        case "cmux_shim_browser_drag_target_enter_source": unsafeBitCast(entered, to: UnsafeMutableRawPointer.self)
        default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
        }
    }
}
