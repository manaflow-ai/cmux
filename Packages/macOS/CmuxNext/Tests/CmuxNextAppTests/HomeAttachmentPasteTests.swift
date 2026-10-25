import AppKit
@testable import CmuxNextHome
import Testing

/// Cmd+V of a picture into Home's (the Chief's) message box: the picture
/// becomes an attachment even when the pasteboard also carries the picture's
/// link as a string (a browser's Copy Image), while real text still pastes
/// as text.
struct HomeAttachmentPasteTests {
    private struct Board: HomePasteboardContents {
        var types: [NSPasteboard.PasteboardType: Data] = [:]
        var text: String?
        var fileURLs: [URL] = []
        /// The pasteboard's items (empty: the board is its one item).
        var items: [any HomePasteboardContents] = []

        func hasType(_ wanted: [NSPasteboard.PasteboardType]) -> Bool {
            wanted.contains { $0 == .string ? text != nil : types[$0] != nil }
        }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? { types[type] }
        func string(forType type: NSPasteboard.PasteboardType) -> String? { type == .string ? text : nil }
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func pictureType(_ inputs: [HomeDraftInput]) -> String? {
        guard inputs.count == 1, case let .data(_, typeIdentifier) = inputs[0] else { return nil }
        return typeIdentifier
    }

    @Test func aBarePictureAttaches() {
        let board = Board(types: [.png: Self.png])
        #expect(HomeAttachmentIntake.offers(board))
        #expect(pictureType(HomeAttachmentIntake.inputs(from: board)) == NSPasteboard.PasteboardType.png.rawValue)
    }

    @Test func aPictureWithItsLinkAttaches() {
        for link in ["https://example.com/cat.png", " file:///tmp/shot.png\n", ""] {
            let board = Board(types: [.png: Self.png], text: link)
            #expect(HomeAttachmentIntake.offers(board), "link: \(link)")
            #expect(pictureType(HomeAttachmentIntake.inputs(from: board)) != nil, "link: \(link)")
        }
    }

    @Test func richTextWithAPictureStaysText() {
        let board = Board(types: [.png: Self.png], text: "Copied paragraph with words")
        #expect(!HomeAttachmentIntake.offers(board))
        #expect(HomeAttachmentIntake.inputs(from: board).isEmpty)
        let word = Board(types: [.tiff: Self.png], text: "hello")
        #expect(HomeAttachmentIntake.inputs(from: word).isEmpty)
    }

    /// A spreadsheet cell or text box holding one link: the app adds rich
    /// text and a picture of the selection, and the link still pastes as text.
    @Test func aLinkInRichTextStaysText() {
        for richType in [NSPasteboard.PasteboardType.rtf, .rtfd, NSPasteboard.PasteboardType("com.apple.flat-rtfd")] {
            let board = Board(types: [.png: Self.png, richType: Data()], text: "https://example.com/report")
            #expect(!HomeAttachmentIntake.offers(board), "rich type: \(richType.rawValue)")
            #expect(HomeAttachmentIntake.inputs(from: board).isEmpty, "rich type: \(richType.rawValue)")
        }
    }

    /// A browser's Copy Image may add rich text too, but it marks the link
    /// as a URL, so the picture still attaches.
    @Test func aPictureWithItsMarkedLinkAndRichTextAttaches() {
        let board = Board(types: [.png: Self.png, .rtfd: Data(), .URL: Data()], text: "https://example.com/cat.png")
        #expect(HomeAttachmentIntake.offers(board))
        #expect(pictureType(HomeAttachmentIntake.inputs(from: board)) != nil)
    }

    // MARK: Several items, and text beside attachments (the user, msg 12179: copy and paste of
    // pictures, text and attachments between other apps and Home's message box is buggy)

    /// Two pictures copied together (Photos, a browser, a design tool) are two items: both attach,
    /// in order, not only the first.
    @Test func everyCopiedPictureAttaches() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let first = Board(types: [.png: Self.png]), second = Board(types: [NSPasteboard.PasteboardType("public.jpeg"): jpeg])
        let board = Board(types: [.png: Self.png], items: [first, second])
        let inputs = HomeAttachmentIntake.inputs(from: board)
        let kinds = inputs.map { input -> String? in
            guard case let .data(_, type) = input else { return nil }
            return type
        }
        #expect(kinds == [NSPasteboard.PasteboardType.png.rawValue, "public.jpeg"])
    }

    /// Finder's Copy: the file's item carries its name as text, which is not text to paste.
    @Test func aCopiedFileHasNoTextBesideIt() {
        let file = URL(fileURLWithPath: "/tmp/report.pdf")
        let item = Board(text: "report.pdf", fileURLs: [file])
        let board = Board(text: "report.pdf", fileURLs: [file], items: [item])
        #expect(HomeAttachmentIntake.inputs(from: board).count == 1)
        #expect(HomeAttachmentIntake.textBeside(board) == nil)
    }

    /// A copy that holds words and a file (the message box's own Copy, Mail, Slack): the files
    /// attach and the words still paste, instead of the words being dropped.
    @Test func wordsBesideCopiedFilesStillPaste() {
        let file = URL(fileURLWithPath: "/tmp/cat.png")
        let words = Board(text: "look at this")
        let fileItem = Board(types: [.png: Self.png], text: "cat.png", fileURLs: [file])
        let board = Board(text: "look at this", fileURLs: [file], items: [words, fileItem])
        #expect(HomeAttachmentIntake.inputs(from: board).count == 1)
        #expect(HomeAttachmentIntake.textBeside(board) == "look at this")
    }

    /// Rich text with pictures in it (Notes, TextEdit, Mail, Pages): the pictures attach and the
    /// words paste, without the pictures' U+FFFC marks; before, the pictures were lost.
    @Test func picturesInsideRichTextAttachBesideItsWords() throws {
        let wrapper = FileWrapper(regularFileWithContents: Self.png)
        wrapper.preferredFilename = "cat.png"
        let rich = NSMutableAttributedString(string: "Hello ")
        rich.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        rich.append(NSAttributedString(string: " world"))
        let rtfd = try #require(rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        let board = Board(types: [.rtfd: rtfd, .png: Self.png], text: "Hello \u{FFFC} world")
        let inputs = HomeAttachmentIntake.inputs(from: board)
        #expect(pictureType(inputs) == NSPasteboard.PasteboardType.png.rawValue)
        #expect(HomeAttachmentIntake.textBeside(board) == "Hello  world")
    }

    /// Rich text with no picture in it still pastes as text alone (nothing attaches).
    @Test func richTextWithoutPicturesAttachesNothing() throws {
        let rich = NSAttributedString(string: "Just words")
        let rtfd = try #require(rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        let board = Board(types: [.rtfd: rtfd, .png: Self.png], text: "Just words")
        #expect(HomeAttachmentIntake.inputs(from: board).isEmpty)
    }

    // MARK: A file link beside the picture

    /// A pasteboard with file links (a `.fileURL` type) and, optionally, the picture's bytes and its name as text.
    private func fileBoard(_ urls: [URL], picture: Bool, text: String? = nil) -> Board {
        var types: [NSPasteboard.PasteboardType: Data] = [.fileURL: Data()]
        if picture { types[.png] = Self.png }
        return Board(types: types, text: text, fileURLs: urls)
    }

    private static func missingShot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NSIRD_screencaptureui_\(UUID().uuidString)/Screenshot 2026-10-23 at 7.24.20 PM.png")
    }

    /// Lawrence 2026-10-23: "paste images with cmd v doesnt work in chief UI". The app's log at
    /// his paste shows three reads of the clipboard's file link and none of its picture: a copied
    /// screenshot carries a link to a file the screenshot tool has already removed, beside the
    /// picture's bytes. The link won, its file was gone, and the picture was never tried.
    @Test func aPictureWhoseFileIsGoneAttachesItsBytes() {
        let shot = Self.missingShot()
        for text: String? in [nil, "Screenshot 2026-10-23 at 7.24.20 PM.png", shot.path, shot.absoluteString] {
            let board = fileBoard([shot], picture: true, text: text)
            #expect(HomeAttachmentIntake.offers(board), "text: \(text ?? "none")")
            #expect(pictureType(HomeAttachmentIntake.inputs(from: board)) == NSPasteboard.PasteboardType.png.rawValue,
                    "text: \(text ?? "none")")
        }
    }

    /// A file that is there still attaches as the file (its name, its own bytes), not the picture.
    @Test func aFileThatIsThereStillAttachesAsTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).png")
        try Self.png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let board = fileBoard([url], picture: true, text: url.lastPathComponent)
        #expect(HomeAttachmentIntake.offers(board))
        let inputs = HomeAttachmentIntake.inputs(from: board)
        guard inputs.count == 1, case let .file(file) = inputs[0] else { Issue.record("not the file: \(inputs)"); return }
        #expect(file == url)
    }

    /// A link to a gone file with no picture: still the file, so the notice says it could not be attached.
    @Test func aGoneFileWithNoPictureStaysTheFile() {
        let board = fileBoard([Self.missingShot()], picture: false)
        let inputs = HomeAttachmentIntake.inputs(from: board)
        guard inputs.count == 1, case .file = inputs[0] else { Issue.record("not the file: \(inputs)"); return }
    }
}
