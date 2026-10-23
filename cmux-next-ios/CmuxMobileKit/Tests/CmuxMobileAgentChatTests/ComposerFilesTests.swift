@testable import CmuxMobileAgentChat
@testable import CmuxMobileArtifacts
import CmuxMobileDesign
import Foundation
import Testing
#if os(iOS)
@testable import CmuxMobileMarkdown
import UIKit
#endif

/// Newlines in the composers (ComposerReturnPolicy) and previews for every
/// kind of file (FilePreview, LocalFileArtifactSource, FileLink).
@Suite struct ComposerReturnPolicyTests {
    @Test func chatReturnOnScreenStartsANewLineAndHardwareReturnSends() {
        let chat = ComposerReturnPolicy(style: .chat, maxLines: 8)
        #expect(chat.action(hardware: false) == .newline)
        #expect(chat.action(hardware: true) == .send)
        #expect(chat.action(hardware: true, shift: true) == .newline)
        #expect(chat.action(hardware: true, option: true) == .newline)
    }

    @Test func terminalReturnSendsFromEitherKeyboardAndShiftReturnBreaksTheLine() {
        let terminal = ComposerReturnPolicy(style: .terminal, maxLines: 6)
        #expect(terminal.action(hardware: false) == .send)
        #expect(terminal.action(hardware: true) == .send)
        #expect(terminal.action(hardware: true, shift: true) == .newline)
        #expect(terminal.action(hardware: true, option: true) == .newline)
    }

    @Test func draftGrowsToMaxLinesThenScrolls() {
        let policy = ComposerReturnPolicy(style: .chat, maxLines: 8)
        #expect(policy.visibleLines(contentLines: 0) == 1)
        #expect(policy.visibleLines(contentLines: 3) == 3)
        #expect(policy.visibleLines(contentLines: 20) == 8)
        #expect(!policy.scrolls(contentLines: 8))
        #expect(policy.scrolls(contentLines: 9))
        #expect(ComposerReturnPolicy(style: .chat, maxLines: 0).maxLines == 1)
    }
}

#if os(iOS)
@MainActor
@Suite struct ComposerReturnTextViewTests {
    @Test func chatFieldTakesTheKeyboardReturnAsANewline() {
        let view = ComposerReturnTextView(policy: ComposerReturnPolicy(style: .chat, maxLines: 8))
        var sent = 0
        view.onSend = { sent += 1 }
        #expect(view.returnShouldInsert("\n"))
        #expect(sent == 0)
        #expect(view.returnShouldInsert("a"))
    }

    @Test func terminalFieldSendsOnTheKeyboardReturnButInsertsItsOwnLineBreak() {
        let view = ComposerReturnTextView(policy: ComposerReturnPolicy(style: .terminal, maxLines: 6))
        let delegate = ReturnDelegate()
        view.delegate = delegate
        var sent = 0
        view.onSend = { sent += 1 }
        #expect(!view.returnShouldInsert("\n"))
        #expect(sent == 1)
        view.text = "echo one"
        view.selectedRange = NSRange(location: 8, length: 0)
        view.insertLineBreak()
        #expect(view.text == "echo one\n")
        #expect(sent == 1)
    }

    @Test func linkedCodePathsInAnswers() {
        #expect(MarkdownFilePath("src/app.swift")?.path == "src/app.swift")
        #expect(MarkdownFilePath("README.md:12") != nil)
        #expect(MarkdownFilePath("/Users/me/report.pdf") != nil)
        #expect(MarkdownFilePath("foo.bar()") == nil)
        #expect(MarkdownFilePath("os.path") == nil)
        #expect(MarkdownFilePath("https://example.com/a.html") == nil)
        #expect(MarkdownFilePath("two words.txt") == nil)
        #expect(MarkdownFilePath("console.log") == nil)
        #expect(MarkdownFilePath("res.json") == nil)
        #expect(MarkdownFilePath("logs/build.log") != nil)
        let rendered = InlineMarkdownCache.render("See `Sources/App/main.swift:4` and `let x = 1`.")
        let links = rendered.runs.compactMap(\.link)
        #expect(links.count == 1)
        #expect(links.first.flatMap { FileLink(url: $0) } == FileLink(url: URL(string: "Sources/App/main.swift:4")!))
    }

    private final class ReturnDelegate: NSObject, UITextViewDelegate {
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let view = textView as? ComposerReturnTextView else { return true }
            return view.insertingLineBreak || view.returnShouldInsert(text)
        }
    }
}
#endif

@Suite struct FilePreviewTests {
    @Test func everyCommonTypeHasAPreviewKind() {
        #expect(TerminalArtifact.kind(forExtension: "HEIC") == .image)
        #expect(TerminalArtifact.kind(forExtension: "mov") == .video)
        #expect(TerminalArtifact.kind(forExtension: "m4a") == .audio)
        #expect(TerminalArtifact.kind(forExtension: "mp3") == .audio)
        #expect(TerminalArtifact.kind(forExtension: "docx") == .document)
        #expect(TerminalArtifact.kind(forExtension: "xlsx") == .document)
        #expect(TerminalArtifact.kind(forExtension: "pages") == .document)
        #expect(TerminalArtifact.kind(forExtension: "pdf") == .pdf)
        #expect(TerminalArtifact.kind(forExtension: "md") == .markdown)
        #expect(TerminalArtifact.kind(forExtension: "html") == .html)
        #expect(TerminalArtifact.kind(forExtension: "kt") == .code)
    }

    @Test func localAttachmentsDecodeLikeMacFiles() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])
        let files = [
            LocalFile(id: "a", name: "Photo", data: png, isImage: true),
            LocalFile(id: "b", name: "notes.txt", data: Data("one\ntwo".utf8), isImage: false),
            LocalFile(id: "c", name: "Quarterly Report.docx", data: Data([1, 2, 3]), isImage: false),
            LocalFile(id: "d", name: "clip.mov", data: Data([0, 0, 0, 1]), isImage: false),
            LocalFile(id: "e", name: "mystery.bin", data: Data([9]), isImage: false),
            LocalFile(id: "f", name: "report.pdf", data: Data("%PDF-1.4".utf8), isImage: false),
        ]
        let request = FilePreviewRequest(files: files, startingAt: "c")
        #expect(request.start == 2)
        #expect(request.artifacts.map(\.kind) == [.image, .text, .document, .video, .binary, .pdf])
        let source = request.source
        guard case .image = try await source.load(request.artifacts[0]) else { Issue.record("image"); return }
        guard case .text("one\ntwo") = try await source.load(request.artifacts[1]) else { Issue.record("text"); return }
        guard case .quickLook(let doc) = try await source.load(request.artifacts[2]) else { Issue.record("docx"); return }
        #expect(doc.lastPathComponent == "Quarterly Report.docx")
        #expect(try Data(contentsOf: doc) == Data([1, 2, 3]))
        guard case .file(let movie) = try await source.load(request.artifacts[3]) else { Issue.record("video"); return }
        #expect(movie.pathExtension == "mov")
        guard case .quickLook = try await source.load(request.artifacts[4]) else { Issue.record("binary"); return }
        guard case .pdf = try await source.load(request.artifacts[5]) else { Issue.record("pdf"); return }
    }

    @Test func aFileWithoutBytesSaysSo() async {
        let request = FilePreviewRequest(files: [LocalFile(id: "x", name: "gone.txt", data: nil, isImage: false)], startingAt: nil)
        await #expect(throws: ArtifactUnavailable.self) { try await request.source.load(request.artifacts[0]) }
    }

    @Test func aMacFileReadsOverTheFallbackSource() async throws {
        let request = FilePreviewRequest(reference: "Sources/App.swift", source: StubSource(), line: 4)
        #expect(request.artifacts.first?.kind == .code)
        #expect(request.artifacts.first?.line == 4)
        guard case .text("// Sources/App.swift") = try await request.source.load(request.artifacts[0]) else { Issue.record("text"); return }
        #expect(FilePreviewRequest.artifact(for: "https://cmux.com").kind == .link)
        #expect(FilePreviewRequest.artifact(for: "build/output.weird").kind == .binary)
        #expect(FilePreviewRequest.artifact(for: "Makefile").kind == .text)
    }

    @Test func localCopiesKeepTheirNameAndAreStable() throws {
        let one = try ArtifactLocalCopy(data: Data([1]), name: "a/b:c.txt", key: "k").url
        let again = try ArtifactLocalCopy(data: Data([2]), name: "a/b:c.txt", key: "k").url
        let other = try ArtifactLocalCopy(data: Data([3]), name: "a/b:c.txt", key: "other").url
        #expect(one.lastPathComponent == "a-b-c.txt")
        #expect(one == again)
        #expect(one != other)
        #expect(try Data(contentsOf: again) == Data([2]))
        #expect(try ArtifactLocalCopy(data: Data(), name: "..", key: "k", defaultExtension: "mp4").url.lastPathComponent == "file.mp4")
    }

    @Test func fileLinksInAnswers() {
        #expect(FileLink(url: URL(string: "https://cmux.com/docs")!) == nil)
        #expect(FileLink(url: URL(string: "mailto:a@b.c")!) == nil)
        #expect(FileLink(url: URL(string: "#section")!) == nil)
        let relative = FileLink(url: URL(string: "Sources/App/main.swift")!)
        #expect(relative?.reference == "Sources/App/main.swift")
        #expect(relative?.line == nil)
        let lined = FileLink(url: URL(string: "src/a.rs:42:7")!)
        #expect(lined?.reference == "src/a.rs")
        #expect(lined?.line == 42)
        let bare = FileLink(url: URL(string: "README.md:12")!)
        #expect(bare?.reference == "README.md")
        #expect(bare?.line == 12)
        let file = FileLink(url: URL(string: "file:///Users/me/My%20Doc.pdf")!)
        #expect(file?.reference == "/Users/me/My Doc.pdf")
        #expect(FileLink(url: URL(string: "maps:?q=coffee")!) == nil)
        #expect(FileLink(url: URL(string: "shortcuts:run-shortcut")!) == nil)
        #expect(FileLink(url: URL(string: "Makefile:3")!)?.line == 3)
        #expect(FileLink(url: URL(string: "file:///Users/me/a.swift#L12")!)?.line == 12)
        let anchored = FileLink(url: URL(string: "docs/plan.md#L10")!)
        #expect(anchored?.reference == "docs/plan.md")
        #expect(anchored?.line == 10)
    }

    @Test func attachmentsOpenFromTheirOwnBytes() {
        let attachment = AgentAttachment(id: "id1", kind: .file, name: "deck.pptx", data: Data([1]))
        #expect(attachment.localFile.kind == .document)
        #expect(attachment.localFile.reference.hasPrefix(LocalFileArtifactSource.scheme))
        #expect(AgentAttachment(kind: .image, name: "Photo", data: Data([1])).localFile.kind == .image)
    }

    private struct StubSource: ArtifactSource {
        func load(_ artifact: TerminalArtifact) async throws -> ArtifactContent { .text("// \(artifact.reference)") }
    }
}
