import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// Issue 51939: a picture pasted in the message box opened nothing when clicked. A click on it opens the large
/// picture viewer (as a picture bubble in the transcript does), with the box's other pictures; Esc closes it.
@MainActor @Suite(.serialized) struct HomeDraftPicturePreviewTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static func picture(_ id: ID, name: String = "") -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: id, kind: "image", fileName: name, mimeType: "image/png", byteSize: 1,
                                   asset: "file:///tmp/thumbs/\(id).png", poster: nil, width: 40, height: 30,
                                   durationSeconds: nil, transfer: .done)
    }

    static func file(_ id: ID) -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: id, kind: "file", fileName: "\(id).pdf", mimeType: "application/pdf", byteSize: 1,
                                   asset: nil, poster: nil, width: nil, height: nil, durationSeconds: nil, transfer: .done)
    }

    // MARK: The gallery

    @Test func theGalleryIsTheBoxsPicturesOpenOnTheOneClicked() throws {
        let draft = [Self.picture("a", name: "a.png"), Self.file("doc"), Self.picture("c", name: "c.png")]
        let gallery = try #require(HomePictureGallery(draft: draft, opening: "c") { URL(fileURLWithPath: "/tmp/named/\($0).png") })
        #expect(gallery.items.map(\.title) == ["a.png", "c.png"], "the file is not a picture")
        #expect(gallery.index == 1)
        #expect(gallery.current?.url == URL(fileURLWithPath: "/tmp/named/c.png"), "the full picture, not the thumbnail")
        #expect(gallery.current?.thumbnail == URL(string: "file:///tmp/thumbs/c.png"))
    }

    @Test func aPictureWithNoFileYetOpensItsThumbnail() throws {
        let gallery = try #require(HomePictureGallery(draft: [Self.picture("a")], opening: "a") { _ in nil })
        #expect(gallery.current?.url == URL(string: "file:///tmp/thumbs/a.png"))
        #expect(gallery.current?.title == CmuxStrings.pictureUntitled)
    }

    @Test func aFileOrAMissingIdOpensNoGallery() {
        let draft = [Self.picture("a"), Self.file("doc")]
        #expect(HomePictureGallery(draft: draft, opening: "doc") { _ in nil } == nil)
        #expect(HomePictureGallery(draft: draft, opening: "gone") { _ in nil } == nil)
    }

    // MARK: The click

    @Test func aPressAndReleaseInPlaceIsAClickAndADragIsNot() {
        #expect(ComposeInlineAttachmentView.isClick(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 11)))
        #expect(!ComposeInlineAttachmentView.isClick(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 10)))
    }

    @Test func aClickedPictureAsksItsFieldToOpenIt() {
        let field = FieldTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        var opened: [ID] = []
        field.onOpenDraftPicture = { id, _ in opened.append(id); return true }
        let picture = ComposeInlineAttachment(Self.picture("p1"), scale: 2)
        let view = picture.makeView()
        field.addSubview(view)
        #expect(view.openPreview())
        #expect(opened == ["p1"])

        let pill = ComposeInlineAttachment(Self.file("doc"), scale: 2)
        let pillView = pill.makeView()
        field.addSubview(pillView)
        #expect(!pillView.openPreview(), "a file pill does not open the picture viewer")
        #expect(opened == ["p1"])
        withExtendedLifetime((picture, pill)) {}
    }

    // MARK: The real box

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    private func screenshot(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func inlineViews(in view: NSView) -> [ComposeInlineAttachmentView] {
        view.subviews.flatMap { v in (v as? ComposeInlineAttachmentView).map { [$0] } ?? inlineViews(in: v) }
    }

    /// The real view over a real store: two screenshots pasted in the box; a click on the second opens the viewer on
    /// it, with both pictures, and closing it leaves the box as it was.
    @Test func aPastedScreenshotOpensLargeWhenClickedAndClosesAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let conversation = ConversationID("conv_chief")
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("blobs"),
                              cache: HomeCache(url: root.appendingPathComponent("home.json")), cacheWriteDelay: .zero)
        store.start()
        defer { store.stop() }
        await until { store.me != nil && store.isOnline }
        await store.open(conversation)
        await until { !store.transcript(for: conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: conversation, me: me, wake: NoWake(), replies: .streaming)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        defer { view.stop(); window.close() }
        view.layoutSubtreeIfNeeded()
        view.projection.refresh()

        let first = try await store.prepareAttachment(data: try screenshot(width: 64, height: 40), typeIdentifier: UTType.png.identifier)
        await view.addDraftAttachment(first)
        let second = try await store.prepareAttachment(data: try screenshot(width: 80, height: 30), typeIdentifier: UTType.png.identifier)
        await view.addDraftAttachment(second)
        #expect(view.draftAttachments == [first, second])
        #expect(view.controller.pictureViewer == nil)

        let ids = view.controller.store?.state.ui.draft.attachments.map(\.id) ?? []
        #expect(ids.count == 2)
        let clicked = try #require(ids.last)
        view.layoutSubtreeIfNeeded()
        // The click: the field's own view of that picture when it placed one (a window on screen), else the
        // controller's entry that view calls.
        if let placed = inlineViews(in: view).first(where: { $0.attachmentID == clicked }) {
            #expect(placed.openPreview())
        } else {
            #expect(view.controller.openDraftPicture(clicked))
        }
        let viewer = try #require(view.controller.pictureViewer, "the click opened no viewer")
        #expect(viewer.gallery.items.count == 2, "the box's two pictures")
        #expect(viewer.gallery.index == 1, "open on the one clicked")
        #expect(viewer.gallery.current?.url.isFileURL == true)
        #expect(FileManager.default.fileExists(atPath: viewer.gallery.current?.url.path ?? ""), "the draft's own file")

        viewer.close()
        await until { view.controller.pictureViewer == nil }
        #expect(view.controller.pictureViewer == nil, "closing leaves the box")
        #expect(view.draftAttachments == [first, second], "the pictures stay in the box")
    }

    // MARK: The size it opens at

    @Test func aSmallPictureGrowsToFillThePaneAndALargeOneShrinksToFit() {
        let room = CGSize(width: 760, height: 580)
        // The user's screenshot: a 380 x 120 px paste drew at 190 x 60 pt in an empty viewer.
        let small = HomePictureViewer.fitMagnification(CGSize(width: 190, height: 60), in: room)
        #expect(abs(190 * small - 760) < 0.5, "fills the pane's width: \(190 * small) pt")
        #expect(60 * small <= 580)
        // A Retina screenshot (2880 x 1800 px, 1440 x 900 pt) fits, never past the pane.
        let large = HomePictureViewer.fitMagnification(CGSize(width: 1440, height: 900), in: room)
        #expect(large < 1)
        #expect(abs(1440 * large - 760) < 0.5 && 900 * large <= 580)
        // A tall picture fits the height; a tiny one stops at the zoom range's top.
        let tall = HomePictureViewer.fitMagnification(CGSize(width: 100, height: 400), in: room)
        #expect(abs(400 * tall - 580) < 0.5)
        #expect(HomePictureViewer.fitMagnification(CGSize(width: 4, height: 4), in: room) == 8)
        #expect(HomePictureViewer.fitMagnification(.zero, in: room) == 1)
    }

    /// The real viewer over a pane: the small paste opens filling the picture area, and still zooms in and out.
    @Test func theViewerOpensASmallPasteLargeAndItStillZooms() async throws {
        let (_, controller) = HomePictureViewerKeysAndWheelTests.pane()
        let picture = try HomePictureViewerTests.image(width: 380, height: 120, gray: 0.5)
        controller.presentPictures(HomePictureViewerKeysAndWheelTests.gallery()) { _ in picture }
        let viewer = try #require(controller.pictureViewer)
        viewer.reduceMotion = { true }
        await viewer.loaded()
        viewer.layoutSubtreeIfNeeded()
        let scroll = try HomePictureViewerKeysAndWheelTests.scrollView(viewer)
        let canvas = try #require(scroll.documentView)
        let drawn = canvas.frame.width * scroll.magnification
        #expect(drawn >= scroll.frame.width * 0.95, "the picture draws \(drawn) pt wide in a \(scroll.frame.width) pt area")
        let fitted = scroll.magnification
        _ = viewer.handle(.zoomIn)
        #expect(scroll.magnification > fitted, "zooms in from fit")
        _ = viewer.handle(.zoomOut)
        _ = viewer.handle(.zoomOut)
        #expect(scroll.magnification < fitted, "zooms out from fit")
        _ = viewer.handle(.fit)
        #expect(abs(scroll.magnification - fitted) < 0.001, "Command-0 fits again")
        viewer.close()
    }
}
