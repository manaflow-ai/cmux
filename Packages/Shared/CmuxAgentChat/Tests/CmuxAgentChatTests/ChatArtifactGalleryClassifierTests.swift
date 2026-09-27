import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery classifier")
struct ChatArtifactGalleryClassifierTests {
    struct Fixture: Sendable, CustomTestStringConvertible {
        let path: String
        let kind: ChatArtifactKind
        let expected: ChatArtifactGalleryFilter?
        let expectedGlyph: ChatArtifactGalleryGlyphPresentation

        var testDescription: String { "\(kind.rawValue):\(path)" }
    }

    @Test(arguments: [
        Fixture(
            path: "/tmp/photo.swift",
            kind: .image,
            expected: .images,
            expectedGlyph: .init(systemImageName: "photo", tint: .secondary)
        ),
        Fixture(
            path: "/tmp/folder.png",
            kind: .directory,
            expected: .folders,
            expectedGlyph: .init(systemImageName: "folder", tint: .accent)
        ),
        Fixture(
            path: "/tmp/App.swift",
            kind: .text,
            expected: .code,
            expectedGlyph: .init(
                systemImageName: "chevron.left.forwardslash.chevron.right",
                tint: .accent
            )
        ),
        Fixture(
            path: "/tmp/seed.py",
            kind: .text,
            expected: .code,
            expectedGlyph: .init(
                systemImageName: "chevron.left.forwardslash.chevron.right",
                tint: .accent
            )
        ),
        Fixture(
            path: "/tmp/main.CPP",
            kind: .binary,
            expected: .code,
            expectedGlyph: .init(
                systemImageName: "chevron.left.forwardslash.chevron.right",
                tint: .accent
            )
        ),
        Fixture(
            path: "/tmp/run.log",
            kind: .text,
            expected: .logs,
            expectedGlyph: .init(systemImageName: "text.alignleft", tint: .accent)
        ),
        Fixture(
            path: "/tmp/process.OUT",
            kind: .binary,
            expected: .logs,
            expectedGlyph: .init(systemImageName: "text.alignleft", tint: .accent)
        ),
        Fixture(
            path: "/tmp/report.PDF",
            kind: .binary,
            expected: .docs,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .accent)
        ),
        Fixture(
            path: "/tmp/report.docx",
            kind: .binary,
            expected: .docs,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .accent)
        ),
        Fixture(
            path: "/tmp/README.md",
            kind: .text,
            expected: .docs,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .accent)
        ),
        Fixture(
            path: "/tmp/notes.txt",
            kind: .text,
            expected: .docs,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .accent)
        ),
        Fixture(
            path: "/tmp/table.numbers",
            kind: .binary,
            expected: .docs,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .accent)
        ),
        Fixture(
            path: "/tmp/archive.zip",
            kind: .binary,
            expected: nil,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .secondary)
        ),
        Fixture(
            path: "/tmp/LICENSE",
            kind: .text,
            expected: nil,
            expectedGlyph: .init(systemImageName: "doc.text", tint: .accent)
        ),
    ])
    func classifiesKindAndExtensionMatrix(_ fixture: Fixture) {
        let classifier = ChatArtifactGalleryClassifier()

        #expect(classifier.filter(for: fixture.kind, path: fixture.path) == fixture.expected)
        #expect(classifier.glyphPresentation(for: fixture.kind, path: fixture.path) == fixture.expectedGlyph)
    }
}
