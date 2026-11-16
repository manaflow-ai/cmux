import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
@testable import CmuxNextHome
import ImageIO
import Testing
import UniformTypeIdentifiers
import CmuxNextTestSupport

/// Lawrence 2026-10-20: "I want people to drag images into Chief properly."
///
/// A drag of files or pictures from another app (Finder, the screenshot thumbnail, Photos, Preview,
/// a browser) anywhere over Home's pane, in every Home container, lands in the message box as a paste
/// does. The drags reach Home's views as AppKit delivers them: the destination is the deepest view
/// under the pointer registered for one of the drag's types (as AppKit finds it), which gets
/// `draggingEntered`, a few `draggingUpdated`, `performDragOperation` and `draggingEnded`. What the
/// drag carries is a value the intake reads (`drop.contents`): the CI Macs' pasteboard server answers
/// reads inconsistently (`HomePasteAnywhereTests`), and the user's drag and clipboard are never touched.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(3))) struct HomeImageDropTests {
    /// One drag session: a private pasteboard, its sequence number and the pointer in window coordinates.
    @MainActor final class Drag: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.home-drop-test.\(UUID().uuidString)"))
        let draggingSequenceNumber: Int
        var location: NSPoint
        weak var window: NSWindow?
        init(sequence: Int, at location: NSPoint, in window: NSWindow) {
            draggingSequenceNumber = sequence
            self.location = location
            self.window = window
        }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
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
        func release() { draggingPasteboard.releaseGlobally() }
        /// The destination's answer to `draggingEntered`, as AppKit's drag session keeps it: NSView's
        /// default `draggingUpdated:` returns it (a view that overrides only `draggingEntered:`).
        var enteredOperation: NSDragOperation = []
        @objc func _lastDragDestinationOperation() -> UInt { enteredOperation.rawValue }
    }

    /// A source app's file promise (the screenshot thumbnail, Photos): it writes its file on the
    /// drop's queue when the drop asks, as `NSFilePromiseReceiver` reports a source's write.
    final class Promise: HomeFilePromise {
        let name: String
        let bytes: Data
        private(set) var asked = 0
        init(name: String, bytes: Data) {
            self.name = name
            self.bytes = bytes
        }
        var fileTypes: [String] { [UTType.png.identifier] }
        func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any], operationQueue: OperationQueue,
                                  reader: @escaping (URL, (any Error)?) -> Void) {
            asked += 1
            let url = destinationDir.appendingPathComponent(name), bytes = bytes
            nonisolated(unsafe) let reader = reader
            operationQueue.addOperation {
                do {
                    try bytes.write(to: url)
                    reader(url, nil)
                } catch {
                    reader(url, error)
                }
            }
        }
    }

    /// What a drag carries: files (Finder), promises, picture bytes by type, text.
    struct Board: HomePasteboardContents {
        var fileURLs: [URL] = []
        var promises: [Promise] = []
        var bytes: [NSPasteboard.PasteboardType: Data] = [:]
        var text: String?
        var link = false
        /// The promise types are on the pasteboard, but no promise reads (a source that answers late).
        var promiseTypesOnly = false

        var types: [NSPasteboard.PasteboardType] {
            var out = Array(bytes.keys)
            if !fileURLs.isEmpty { out.append(.fileURL) }
            if !promises.isEmpty || promiseTypesOnly { out += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } }
            if text != nil { out.append(.string) }
            if link { out.append(.URL) }
            return out
        }
        func hasType(_ wanted: [NSPasteboard.PasteboardType]) -> Bool { wanted.contains { types.contains($0) } }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? { bytes[type] }
        func string(forType type: NSPasteboard.PasteboardType) -> String? { type == .string ? text : nil }
        var filePromises: [any HomeFilePromise] { promises }
    }

    enum Container: String, CaseIterable { case dock, homeTab, conversationTab }

    struct Harness {
        let window: NSWindow
        let content: TabContent
        let home: HomeHostView
        let list: NSView?

        var transcript: HomeNativeTranscriptView { home.transcript }
        var drafted: [String] { transcript.transcript.draftAttachments.map(\.ref.name) }

        /// The drag's destination over `view`, as AppKit picks it for a pointer there: the deepest view
        /// from `view` up registered for one of the drag's types. (Geometry is not used: a CI Mac with
        /// no display shrinks the test window to a point.)
        func destination(over view: NSView, for types: [NSPasteboard.PasteboardType]) -> NSView? {
            let types = Set(types)
            var next: NSView? = view
            while let candidate = next {
                if !types.isDisjoint(with: candidate.registeredDraggedTypes) { return candidate }
                next = candidate.superview
            }
            return nil
        }

        /// A whole drag of `board` over `view`: entered, moves, the drop and the end. The operation the
        /// destination showed over it, whether the pane's drop highlight showed meanwhile, whether the
        /// drop was taken, and whether the highlight was gone after the drag.
        func drop(_ board: Board, sequence: Int, over view: NSView) -> (operation: NSDragOperation, highlighted: Bool, dropped: Bool, cleared: Bool) {
            showConversation()
            transcript.drop.contents = { _ in board }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let drag = Drag(sequence: sequence, at: point, in: window)
            defer { drag.release() }
            guard let target = destination(over: view, for: board.types) else { return ([], false, false, true) }
            var operation = target.draggingEntered(drag)
            drag.enteredOperation = operation
            // AppKit sends the optional messages only to a destination that implements them.
            if target.responds(to: #selector(NSDraggingDestination.draggingUpdated(_:))) {
                for _ in 0..<5 { operation = target.draggingUpdated(drag) }
            }
            // Showing, and drawn over the pane: a finite frame, inside the transcript's bounds when the pane
            // has room (a CI Mac with no display shrinks the test window to a point).
            let outline = transcript.drop.highlight.frame, pane = transcript.bounds
            let roomy = pane.width > 2 * HomeDropHighlightView.inset && pane.height > 2 * HomeDropHighlightView.inset
            let highlighted = transcript.drop.highlight.isShowing && !outline.isNull && outline.minX.isFinite && outline.minY.isFinite
                && (!roomy || (pane.contains(outline) && outline.width > 0))
            // The message box's own text drop (NSTextView) reads private drag state this stand-in drag
            // does not have: the box drops here only when Home's intake took the drag (its highlight shows).
            let intakeTook = !(target is NSTextView) || transcript.drop.highlight.isShowing
            let dropped = operation.contains(.copy) && intakeTook && target.performDragOperation(drag)
            // NSTextView's own drag end reads private drag-session state this stand-in lacks.
            if target is NSTextView {
                target.draggingExited(nil)
            } else if target.responds(to: #selector(NSDraggingDestination.draggingEnded(_:))) {
                target.draggingEnded(drag)
            }
            return (operation, highlighted, dropped, !transcript.drop.highlight.isShowing)
        }

        /// The test process serves no local conversations, so Home would show why it can't (and may say
        /// so again when its availability changes); the drop target is the conversation's own view, shown
        /// as when its owner answers.
        func showConversation() {
            home.transcript.isHidden = false
            for label in home.subviews where label is NSTextField { label.isHidden = true }
        }

        /// Views of the pane a pointer can be over: the transcript's rows, its header, the message box,
        /// and the conversation list (Home tab and dock only).
        var places: [(String, NSView)] {
            var all: [NSView] = []
            var stack: [NSView] = [transcript]
            while let next = stack.popLast() {
                all.append(next)
                stack.append(contentsOf: next.subviews)
            }
            func named(_ name: String) -> NSView? { all.first { "\(type(of: $0))" == name } }
            var out: [(String, NSView)] = []
            if let rows = named("TranscriptDocumentView") { out.append(("transcript", rows)) }
            if let header = named("PaneHeaderView") { out.append(("header", header)) }
            out.append(("field", transcript.primaryInput))
            if let list { out.append(("list", list)) }
            return out
        }

        func close() { window.closeWithHomePopovers() }
    }

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private static func harness(_ container: Container) async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let conversation = ConversationID("conv_image_drop")
        let content: TabContent
        let host: () -> HomeHostView?
        var list: NSView?
        switch container {
        case .dock:
            let dock = HomeDockView(services: services, mode: .messages)
            dock.messages?.show(conversation)
            content = .page(InternalPageView(key: "image-drop-dock", page: .homeDock, content: dock))
            host = { dock.messages?.host }
            list = dock.messages?.list
        case .homeTab:
            let page = TopHomePageView(services: services, windowKey: { "image-drop" })
            page.show(conversation)
            content = .page(InternalPageView(key: "image-drop-tab", page: .homeTab, content: page))
            host = { page.host }
            list = page.list
        case .conversationTab:
            let view = HomeHostView(services: services, conversation: conversation.rawValue)
            content = .conversation(view)
            host = { view }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        window.contentView = content.view
        window.makeKeyAndOrderFront(nil)
        content.view.layoutSubtreeIfNeeded()
        await wait { host()?.focusTarget is NSTextView }
        let home = try #require(host(), "Home shows no conversation")
        let harness = Harness(window: window, content: content, home: home, list: list)
        harness.showConversation()
        content.view.layoutSubtreeIfNeeded()
        return harness
    }

    // MARK: Pictures

    private static func picture(_ type: UTType, width: Int = 64, height: Int = 48) -> Data? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let cg = rep.cgImage else { return nil }
        if type == .pdf {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
            pdf.beginPDFPage(nil)
            pdf.setFillColor(NSColor.systemOrange.cgColor)
            pdf.fill(box)
            pdf.endPDFPage()
            pdf.closePDF()
            return data as Data
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Picture files as Finder drags them: png, jpg, gif, pdf, and heic where this Mac encodes it.
    private static func files() throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("home-image-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (type, ext) in [(UTType.png, "png"), (.jpeg, "jpg"), (.gif, "gif"), (.pdf, "pdf"), (.heic, "heic")] {
            guard let data = picture(type) else { continue }
            let url = folder.appendingPathComponent("dropped.\(ext)")
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    // MARK: Drags

    /// Finder: one file, then several at once, dropped on every part of the pane.
    @Test(arguments: Container.allCases)
    func finderFilesDroppedAnywhereOnThePaneAttach(_ container: Container) async throws {
        let urls = try Self.files()
        try #require(urls.count >= 4, "this Mac made \(urls.count) picture files")
        let h = try await Self.harness(container)
        defer { h.close() }
        var sequence = 0
        let places = h.places
        #expect(places.count >= (container == .conversationTab ? 3 : 4), "\(container): the pane has \(places.map(\.0))")
        for (place, view) in places {
            for batch in [[urls[0]], urls] {
                sequence += 1
                let (operation, highlighted, dropped, cleared) = h.drop(Board(fileURLs: batch), sequence: sequence, over: view)
                await h.transcript.attachmentsReady()
                #expect(operation == .copy, "\(container) \(place): \(batch.count) files showed \(operation)")
                #expect(highlighted && cleared, "\(container) \(place): the drop highlight showed \(highlighted), stayed \(!cleared)")
                #expect(dropped, "\(container) \(place): \(batch.count) files were not taken")
                #expect(h.drafted.count == batch.count, "\(container) \(place): \(batch.count) files, the draft holds \(h.drafted)")
                h.transcript.removeDraftAttachments(h.transcript.draftAttachmentHashes)
            }
        }
    }

    /// The screenshot thumbnail and Photos drag a file promise, not a file: the drop asks the source
    /// to write it, the notice says it is coming, and it attaches under its own name.
    @Test(arguments: Container.allCases)
    func aPromisedFileAttaches(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let bytes = try #require(Self.picture(.png))
        let source = Promise(name: "Screenshot 2026-10-20 at 21.00.00.png", bytes: bytes)
        let rows = try #require(h.places.first { $0.0 == "transcript" }?.1)
        let (operation, highlighted, dropped, _) = h.drop(Board(promises: [source]), sequence: 900, over: rows)
        let pendingShown = h.transcript.notice == HomeStrings.attachPending
        await h.transcript.attachmentsReady()
        #expect(operation == .copy && highlighted, "\(container): a file promise showed \(operation), highlight \(highlighted)")
        #expect(dropped)
        #expect(source.asked == 1, "\(container): the source was asked \(source.asked) times")
        #expect(pendingShown, "\(container): no pending notice while the promised file came")
        #expect(h.drafted == [source.name], "\(container): the draft holds \(h.drafted)")
        #expect(h.transcript.notice == nil, "\(container): the notice stayed: \(h.transcript.notice ?? "")")
    }

    /// A browser's picture: a promise of its file the drag can't read before the drop, its bytes and its
    /// link. The bytes alone make the drag a picture drop (the promise answered nothing).
    @Test func aBrowserPictureWithAnUnreadablePromiseAttachesItsBytes() async throws {
        let h = try await Self.harness(.homeTab)
        defer { h.close() }
        let data = try #require(Self.picture(.png))
        let rows = try #require(h.places.first { $0.0 == "transcript" }?.1)
        var board = Board(bytes: [.png: data], text: "https://example.com/cat.png", link: true)
        board.promiseTypesOnly = true
        let (operation, _, dropped, _) = h.drop(board, sequence: 902, over: rows)
        await h.transcript.attachmentsReady()
        #expect(operation == .copy && dropped, "a browser picture showed \(operation), dropped \(dropped)")
        #expect(h.drafted.count == 1, "the draft holds \(h.drafted)")
    }

    /// Preview's selection and a browser's picture carry picture bytes (TIFF, PDF, GIF) with no file;
    /// a browser adds the picture's link.
    @Test(arguments: [(NSPasteboard.PasteboardType.tiff, UTType.tiff), (.pdf, .pdf), (NSPasteboard.PasteboardType("com.compuserve.gif"), .gif)])
    func pictureBytesAttach(_ type: NSPasteboard.PasteboardType, _ format: UTType) async throws {
        let h = try await Self.harness(.homeTab)
        defer { h.close() }
        let data = try #require(Self.picture(format))
        let rows = try #require(h.places.first { $0.0 == "transcript" }?.1)
        let board = Board(bytes: [type: data], text: "https://example.com/cat.\(format.preferredFilenameExtension ?? "img")", link: true)
        let (operation, _, dropped, _) = h.drop(board, sequence: 901, over: rows)
        await h.transcript.attachmentsReady()
        #expect(operation == .copy, "\(type.rawValue) showed \(operation)")
        #expect(dropped)
        #expect(h.drafted.count == 1, "\(type.rawValue): the draft holds \(h.drafted)")
    }

    /// Text and link drags are not attachments: the pane takes none of them (the field types text,
    /// and a link keeps the panes' link drop zones).
    @Test func textAndLinkDragsAreNotTaken() async throws {
        let h = try await Self.harness(.homeTab)
        defer { h.close() }
        for (index, (place, view)) in h.places.enumerated() where place != "field" {
            let board = Board(text: "https://example.com/page", link: true)
            let (operation, highlighted, dropped, _) = h.drop(board, sequence: 950 + index, over: view)
            #expect(operation != .copy && !dropped && !highlighted, "\(place): a link drag was taken or highlighted")
        }
        #expect(h.drafted.isEmpty)
    }
}
