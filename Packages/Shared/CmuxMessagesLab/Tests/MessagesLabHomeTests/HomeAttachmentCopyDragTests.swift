import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The user, 2026-10-21: "in chief i need to be able to right click any image/video etc 'copy' i
/// need to be able to drag it out to other apps too". A Home attachment's menu has Copy (the
/// real file, and an image's own pixels, so it pastes into Messages, Finder, Slack and Preview)
/// and Save As…; a press on an attachment that moves drags the file itself out of cmux.
@MainActor @Suite(.serialized) struct HomeAttachmentCopyDragTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-copy-drag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real 4×3 PNG named `name` in a new folder.
    private static func png(_ name: String = "shot.png") throws -> URL {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.setColor(.systemRed, atX: 1, y: 1)
        let file = try folder().appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
        return file
    }

    /// The file URL an item carries.
    private static func fileURL(_ item: NSPasteboardItem) -> URL? {
        item.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL
    }

    // MARK: Copy
    // The item is checked, not a written pasteboard: the CI Macs' pasteboard server answers
    // writes and reads inconsistently (HomePasteAnywhereTests), and the user's clipboard stays.

    @Test func copyingAnImageOffersTheFileAndItsPixels() throws {
        let file = try Self.png()
        let item = HomeAttachmentPasteboard().item(for: file)
        #expect(Self.fileURL(item) == file.standardizedFileURL)
        #expect(item.data(forType: .png) == (try Data(contentsOf: file)))
        // Apps that read only TIFF (older Cocoa apps, Preview's New from Clipboard) get the image too.
        let tiff = try #require(item.data(forType: .tiff))
        #expect(NSImage(data: tiff)?.representations.first?.pixelsWide == 4)
    }

    @Test func copyingAVideoOffersTheFileOnly() throws {
        let file = try Self.folder().appendingPathComponent("clip.mp4")
        try Data("not really a movie".utf8).write(to: file)
        let item = HomeAttachmentPasteboard().item(for: file)
        #expect(Self.fileURL(item) == file.standardizedFileURL)
        #expect(item.data(forType: .png) == nil)
        #expect(item.data(forType: .tiff) == nil)
    }

    @Test func theAttachmentRowsOfferCopyAndSaveAs() async throws {
        _ = NSApplication.shared
        let file = try Self.png()
        var copied: [NSPasteboardItem] = []
        let rows = HomeAttachmentRows(copyItem: { copied.append($0); return true })
        let titles = rows.items(name: "shot.png", resolve: { file }).compactMap { ($0 as? MenuAction)?.label }
        #expect(titles == [CmuxStrings.copyAttachment, CmuxStrings.saveAttachmentAs])
        #expect(await rows.copy(resolve: { file }))
        #expect(copied.map(Self.fileURL) == [file.standardizedFileURL])
        #expect(copied.first?.data(forType: .png) != nil)
        #expect(!(await rows.copy(resolve: { nil })))
        #expect(copied.count == 1)
    }

    // MARK: Save As…

    @Test func saveAsWritesTheBytesAndReplacesAnOlderFile() throws {
        let file = try Self.png()
        let destination = try Self.folder().appendingPathComponent("kept.png")
        try Data("old".utf8).write(to: destination)
        try HomeAttachmentSave().save(file, to: destination)
        #expect(try Data(contentsOf: destination) == (try Data(contentsOf: file)))
        // The original stays where it was.
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Drag out

    @Test func aDragOfAFetchedAttachmentCarriesTheFileItself() throws {
        let file = try Self.png()
        let writer = HomeAttachmentDrag(name: "shot.png", resolve: { file }).writer(file: file)
        let item = try #require(writer as? NSPasteboardItem)
        #expect(item.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL == file.standardizedFileURL)
        #expect(item.data(forType: .png) != nil)
    }

    @Test func aDragBeforeTheBytesArriveIsAFilePromiseThatWritesThem() async throws {
        let file = try Self.png()
        let drag = HomeAttachmentDrag(name: "shot.png", resolve: { file })
        let promise = try #require(drag.writer(file: nil) as? NSFilePromiseProvider)
        #expect(promise.fileType == UTType.png.identifier)
        #expect(drag.filePromiseProvider(promise, fileNameForType: promise.fileType) == "shot.png")
        let destination = try Self.folder().appendingPathComponent("shot.png")
        let error: Error? = await withCheckedContinuation { done in
            drag.filePromiseProvider(promise, writePromiseTo: destination) { done.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: destination) == (try Data(contentsOf: file)))
    }

    @Test func aPromiseWhoseBytesCannotBeFetchedFails() async throws {
        let drag = HomeAttachmentDrag(name: "gone.mov", resolve: { nil })
        let promise = try #require(drag.writer(file: nil) as? NSFilePromiseProvider)
        let destination = try Self.folder().appendingPathComponent("gone.mov")
        let error: Error? = await withCheckedContinuation { done in
            drag.filePromiseProvider(promise, writePromiseTo: destination) { done.resume(returning: $0) }
        }
        #expect(error != nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: The gesture in a real transcript

    private func controller() -> (NSWindow, ChatController) {
        let me = ParticipantID("user_me"), chief = ParticipantID("agent_chief")
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let picture = AttachmentRef(hash: "hash_shot", name: "shot.png", mimeType: "image/png", byteCount: 1_234, width: 400, height: 300)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: chief, parts: [.text("Here is the screenshot.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: Seq(2), author: chief, parts: [.attachment(picture)],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let summary = ConversationSummary(id: ConversationID("conv_media"), title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        let (conv, w) = core.install(ConversationID("conv_media"), items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 600, height: 700)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        controller.demo?.layoutIfNeeded()
        controller.demo?.collection.layoutIfNeeded()
        return (window, controller)
    }

    private func attachmentPoint(in controller: ChatController) -> CGPoint? {
        let b = controller.host.bounds
        for y in stride(from: b.minY + 60, to: b.maxY - 80, by: 4) {
            for x in stride(from: b.minX, to: b.maxX, by: 4) {
                let p = CGPoint(x: x, y: y)
                if case .attachment? = controller.demo?.hit(p)?.row.part { return p }
            }
        }
        return nil
    }

    private func event(_ type: NSEvent.EventType, _ p: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aPressOnAnAttachmentThatMovesDragsItOutOnce() throws {
        let (window, controller) = controller()
        var drags: [String] = []
        controller.beginAttachmentDrag = { request, _ in drags.append(request.name) }
        let p = try #require(attachmentPoint(in: controller))
        controller.mouseDown(at: p, event(.leftMouseDown, p, in: window))
        for dx in stride(from: 2.0, through: 40, by: 2) {
            let q = CGPoint(x: p.x + dx, y: p.y)
            controller.mouseDragged(at: q, event(.leftMouseDragged, q, in: window))
        }
        controller.mouseUp(at: CGPoint(x: p.x + 40, y: p.y), event(.leftMouseUp, p, in: window))
        #expect(drags == ["shot.png"])
        #expect(controller.selection.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func aPressOnTextThatMovesStartsNoAttachmentDrag() throws {
        let (window, controller) = controller()
        var drags = 0
        controller.beginAttachmentDrag = { _, _ in drags += 1 }
        let b = controller.host.bounds
        var start: CGPoint?
        outer: for y in stride(from: b.minY + 60, to: b.maxY - 80, by: 4) {
            for x in stride(from: b.minX, to: b.maxX, by: 4) {
                let p = CGPoint(x: x, y: y)
                if case .text? = controller.demo?.hit(p)?.row.part { start = p; break outer }
            }
        }
        let p = try #require(start)
        controller.mouseDown(at: p, event(.leftMouseDown, p, in: window))
        for dx in stride(from: 2.0, through: 40, by: 2) {
            let q = CGPoint(x: p.x + dx, y: p.y)
            controller.mouseDragged(at: q, event(.leftMouseDragged, q, in: window))
        }
        #expect(drags == 0)
        withExtendedLifetime(window) {}
    }

    @Test func theAttachmentMenuLeadsWithCopyAndSaveAs() throws {
        _ = NSApplication.shared
        let (window, controller) = controller()
        let p = try #require(attachmentPoint(in: controller))
        let menu = try #require(controller.menu(at: p))
        controller.menuHighlight?.discard(); controller.menuHighlight = nil
        let labels = menu.items.compactMap { ($0 as? MenuAction)?.label }
        #expect(labels.contains(CmuxStrings.copyAttachment))
        #expect(labels.contains(CmuxStrings.saveAttachmentAs))
        withExtendedLifetime(window) {}
    }
}
