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
}
