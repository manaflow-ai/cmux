import Foundation
import Testing
import CmuxHomeCoreTestSupport
import UniformTypeIdentifiers
@testable import CmuxHomeCore

/// Any file attaches (Lawrence 2026-10-20: "“index.html” can’t be attached …
/// need to fix this"): bytes that read as UTF-8 go as text whatever the
/// name says, other bytes as a generic file; folders and empty files are refused.
@MainActor
@Suite struct AnyFileAttachmentTests {
    private func store(_ root: URL) -> HomeStore {
        HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("cache"))
    }

    @Test func anHTMLFileAttachesAsText() async throws {
        let root = try temporaryDirectory()
        let page = root.appendingPathComponent("index.html")
        try Data("<!doctype html><title>Hi</title><p>héllo</p>\n".utf8).write(to: page)
        #expect(HomeAttachmentPolicy.accepts(fileURL: page))
        let prepared = try await store(root).prepareAttachment(fileURL: page)
        #expect(prepared.ref.name == "index.html")
        #expect(prepared.ref.mimeType == "text/plain")
        #expect(AttachmentPreview.of([.attachment(prepared.ref)]) == AttachmentPreview(kind: .file, count: 1))
    }

    @Test func sourceFilesDotfilesAndExtensionlessTextAttachAsText() async throws {
        let root = try temporaryDirectory()
        for name in ["Makefile", "LICENSE", ".zshrc", "main.swift", "lib.rs", "app.ts", "style.css", "run.sh", "config.toml",
                     "build.log", "values.yaml", "icon.svg"] {
            let file = root.appendingPathComponent(name)
            try Data("line one\n\tline two with ünïcode ✓\n".utf8).write(to: file)
            #expect(HomeAttachmentPolicy.accepts(fileURL: file), "\(name)")
            let prepared = try await store(root).prepareAttachment(fileURL: file)
            #expect(prepared.ref.mimeType == "text/plain", "\(name)")
            #expect(prepared.ref.name == name)
        }
    }

    @Test func anArbitraryBinaryAttachesAsAGenericFile() async throws {
        let root = try temporaryDirectory()
        var bytes = Data([0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x00, 0x03])
        bytes.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        for name in ["state.sqlite", "blob", "firmware.bin", "Setup.exe"] {
            let file = root.appendingPathComponent(name)
            try bytes.write(to: file)
            #expect(HomeAttachmentPolicy.accepts(fileURL: file), "\(name)")
            let prepared = try await store(root).prepareAttachment(fileURL: file)
            #expect(prepared.ref.mimeType == "application/octet-stream", "\(name)")
            #expect(prepared.ref.byteCount == bytes.count)
            #expect(prepared.ref.name == name)
        }
    }

    @Test func pastedBytesOfAnyTypeAttach() async throws {
        let root = try temporaryDirectory()
        let html = try await store(root).prepareAttachment(data: Data("<b>x</b>".utf8), typeIdentifier: UTType.html.identifier)
        #expect(html.ref.mimeType == "text/plain")
        let svg = try await store(root).prepareAttachment(data: Data("<svg/>".utf8), typeIdentifier: UTType.svg.identifier)
        #expect(svg.ref.mimeType == "text/plain")
        let raw = try await store(root).prepareAttachment(data: Data([0, 1, 2, 0xff, 0xfe]), typeIdentifier: UTType.data.identifier)
        #expect(raw.ref.mimeType == "application/octet-stream")
        #expect(HomeAttachmentPolicy.accepts(typeIdentifier: UTType.data.identifier))
        #expect(HomeAttachmentPolicy.accepts(typeIdentifier: UTType.html.identifier))
    }

    @Test func theOwnerCheckTakesAnyNameAndTheGenericType() throws {
        for name in ["index.html", "run.sh", "app.JS", "x.svg", "Setup.dmg", "tool.exe", "Makefile"] {
            try HomeAttachmentPolicy.check(mimeType: "text/plain", byteCount: 1, name: name)
            try HomeAttachmentPolicy.check(mimeType: "application/octet-stream", byteCount: 1, name: name)
        }
    }

    @Test func aFolderIsRefusedAndNamed() async throws {
        let root = try temporaryDirectory()
        let folder = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(!HomeAttachmentPolicy.accepts(fileURL: folder))
        await #expect(throws: HomeAttachmentError.folder(name: "Project")) {
            try await store(root).prepareAttachment(fileURL: folder)
        }
    }

    @Test func textSniffingKeepsACutCharacterAtTheEdge() {
        let text = Data("añb✓".utf8)
        // The prefix ends inside "✓" (3 bytes): still text when more follows.
        #expect(HomeAttachmentPolicy.looksLikeText(text.prefix(text.count - 1), complete: false))
        #expect(!HomeAttachmentPolicy.looksLikeText(text.prefix(text.count - 1), complete: true))
        #expect(!HomeAttachmentPolicy.looksLikeText(Data([0x61, 0x00, 0x62]), complete: true))
        #expect(HomeAttachmentPolicy.looksLikeText(Data("\u{1B}[31mred\u{1B}[0m\r\n".utf8), complete: true))
    }

    /// Active documents still attach, but opening one shows it in Finder
    /// instead of running it.
    @Test func activeFilesOpenInFinderOnly() {
        #expect(HomeAttachmentPolicy.revealsInsteadOfOpening(name: "run.command"))
        #expect(HomeAttachmentPolicy.revealsInsteadOfOpening(name: "index.HTML"))
        #expect(!HomeAttachmentPolicy.revealsInsteadOfOpening(name: "notes.pdf"))
        #expect(!HomeAttachmentPolicy.revealsInsteadOfOpening(name: "Makefile"))
    }
}
