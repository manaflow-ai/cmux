import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact preview routing")
struct ChatArtifactPreviewRouterTests {
    @Test
    func routesMimeAndExtensionMatrix() {
        let fixtures: [(String, ChatArtifactKind, String?, Bool, ChatArtifactPreviewRoute)] = [
            ("/tmp/photo.png", .image, "image/png", false, .image),
            ("/tmp/image-with-pdf-name.pdf", .image, "application/pdf", false, .image),
            ("/tmp/report", .binary, "application/pdf; charset=binary", false, .pdf),
            ("/tmp/report.PDF", .binary, "application/octet-stream", false, .pdf),
            ("/tmp/movie.mp4", .binary, "video/mp4", false, .media),
            ("/tmp/sound.m4a", .binary, "audio/mp4", false, .media),
            ("/tmp/recording", .binary, "video/mp4", false, .media),
            ("/tmp/voice-note", .binary, "audio/mp4; charset=binary", false, .media),
            ("/tmp/README.md", .text, "text/markdown", false, .markdown),
            ("/tmp/notes.MARKDOWN", .text, "text/plain", false, .markdown),
            ("/tmp/plain.txt", .text, "text/plain", false, .text),
            ("/tmp/output", .text, nil, false, .text),
            ("/tmp/report.docx", .binary, nil, false, .quickLook),
            ("/tmp/sheet.xlsx", .binary, nil, false, .quickLook),
            ("/tmp/slides.pptx", .binary, nil, false, .quickLook),
            ("/tmp/document.pages", .binary, nil, false, .quickLook),
            ("/tmp/deck.key", .binary, nil, false, .quickLook),
            ("/tmp/table.numbers", .binary, nil, false, .quickLook),
            ("/tmp/archive.zip", .binary, nil, false, .binary),
            ("/tmp/blob.bin", .binary, nil, false, .binary),
            ("/tmp/folder", .directory, nil, true, .folder),
        ]
        let router = ChatArtifactPreviewRouter()

        for (path, kind, mimeType, isDirectory, expected) in fixtures {
            let stat = ChatArtifactStat(
                exists: true,
                isDirectory: isDirectory,
                size: 12,
                modifiedAt: Date(timeIntervalSince1970: 0),
                kind: kind,
                mimeType: mimeType
            )

            #expect(router.route(stat: stat, path: path) == expected, "Unexpected route for \(path)")
        }
    }

    @Test
    func mimeFallbackExtensionTypesExtensionlessTempFiles() {
        let router = ChatArtifactPreviewRouter()

        #expect(router.preferredExtension(forMIMEType: "video/mp4") == "mp4")
        #expect(router.preferredExtension(forMIMEType: "application/pdf; charset=binary") == "pdf")
        #expect(router.preferredExtension(forMIMEType: "not a mime") == nil)
        #expect(router.preferredExtension(forMIMEType: nil) == nil)
    }
}
