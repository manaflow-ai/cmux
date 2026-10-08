import Foundation
import Testing
@testable import CmuxNextApp

/// Where a path chip's file opens (D4): `link.openPath` hands the file to the pane's file pages
/// (`file.open` with a tab). Active content must open as text in the code editor page, never in
/// the browser preview tab, which renders what it loads.
@Suite struct AgentReplyFilePagesTests {
    @Test func pageTypesOpenAsTextInTheEditorPage() {
        for name in ["index.html", "page.htm", "icon.svg", "feed.xml", "page.xhtml", "notes.webarchive", "Makefile", "main.ts"] {
            #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/repo/\(name)")) == .editor, "\(name)")
        }
        #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/repo/README.md")) == .markdown)
    }

    @Test func onlyImagesPDFsAndMediaUseThePreviewTab() {
        for name in ["shot.png", "photo.jpeg", "paper.pdf", "clip.mp4", "clip.ogv", "song.oga", "movie.webm"] {
            #expect(FilePageOpener.kind(for: URL(fileURLWithPath: "/repo/\(name)")) == nil, "\(name)")
        }
        // An SVG can carry script: it is never previewed.
        #expect(!FilePageOpener.previewExtensions.contains("svg"))
        #expect(!FilePageOpener.previewExtensions.contains("svgz"))
    }
}
