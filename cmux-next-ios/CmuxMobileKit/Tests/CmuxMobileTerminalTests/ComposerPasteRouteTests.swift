import Foundation
import Testing
@testable import CmuxMobileTerminal

/// design/terminal R2-2: Paste attaches a copied file; never types a phone path.
@Suite struct ComposerPasteRouteTests {
    @Test func imageWins() {
        #expect(ComposerPasteRoute.route(hasImage: true, fileURL: URL(fileURLWithPath: "/a.png"), string: "x") == .image)
    }

    @Test func aCopiedFileIsAttached() {
        let url = URL(fileURLWithPath: "/private/var/mobile/Documents/report.pdf")
        #expect(ComposerPasteRoute.route(hasImage: false, fileURL: url, string: url.absoluteString) == .file(url))
    }

    @Test func aFileURLAsTextIsAttachedNotTyped() {
        let route = ComposerPasteRoute.route(hasImage: false, fileURL: nil, string: "file:///private/var/mobile/a.txt\n")
        #expect(route == .file(URL(fileURLWithPath: "/private/var/mobile/a.txt")))
        // A malformed one is dropped, never typed into the shell.
        #expect(ComposerPasteRoute.route(hasImage: false, fileURL: nil, string: "file://") == .nothing)
    }

    @Test func textAndWebLinksGoIntoTheField() {
        #expect(ComposerPasteRoute.route(hasImage: false, fileURL: nil, string: "ls -la") == .text("ls -la"))
        #expect(ComposerPasteRoute.route(hasImage: false, fileURL: URL(string: "https://cmux.com"), string: "https://cmux.com")
                == .text("https://cmux.com"))
        #expect(ComposerPasteRoute.route(hasImage: false, fileURL: nil, string: nil) == .nothing)
    }

    @Test func pasteIsOfferedOnlyForAnImageOrAFile() {
        #expect(ComposerPasteRoute.offersPaste(hasImage: true, hasFileURL: false))
        #expect(ComposerPasteRoute.offersPaste(hasImage: false, hasFileURL: true))
        #expect(!ComposerPasteRoute.offersPaste(hasImage: false, hasFileURL: false))
    }
}
