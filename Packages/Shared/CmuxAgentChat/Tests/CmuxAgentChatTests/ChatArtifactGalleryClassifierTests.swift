import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery classifier")
struct ChatArtifactGalleryClassifierTests {
    struct Fixture: Sendable, CustomTestStringConvertible {
        let path: String
        let kind: ChatArtifactKind
        let expected: ChatArtifactGalleryFilter?
        let expectedSystemImage: String

        var testDescription: String { "\(kind.rawValue):\(path)" }
    }

    @Test(arguments: [
        Fixture(path: "/tmp/photo.swift", kind: .image, expected: .images, expectedSystemImage: "photo"),
        Fixture(path: "/tmp/folder.png", kind: .directory, expected: .folders, expectedSystemImage: "folder"),
        Fixture(path: "/tmp/App.swift", kind: .text, expected: .code, expectedSystemImage: "chevron.left.forwardslash.chevron.right"),
        Fixture(path: "/tmp/main.CPP", kind: .binary, expected: .code, expectedSystemImage: "chevron.left.forwardslash.chevron.right"),
        Fixture(path: "/tmp/run.log", kind: .text, expected: .logs, expectedSystemImage: "text.alignleft"),
        Fixture(path: "/tmp/process.OUT", kind: .binary, expected: .logs, expectedSystemImage: "text.alignleft"),
        Fixture(path: "/tmp/notes.txt", kind: .text, expected: .docs, expectedSystemImage: "doc.text"),
        Fixture(path: "/tmp/README.md", kind: .text, expected: .docs, expectedSystemImage: "doc.text"),
        Fixture(path: "/tmp/report.PDF", kind: .binary, expected: .docs, expectedSystemImage: "doc.text"),
        Fixture(path: "/tmp/deck.pptx", kind: .binary, expected: .docs, expectedSystemImage: "doc.text"),
        Fixture(path: "/tmp/table.numbers", kind: .binary, expected: .docs, expectedSystemImage: "doc.text"),
        Fixture(path: "/tmp/archive.zip", kind: .binary, expected: nil, expectedSystemImage: "doc.text"),
        Fixture(path: "/tmp/LICENSE", kind: .text, expected: nil, expectedSystemImage: "doc.text"),
    ])
    func classifiesKindAndExtensionMatrix(_ fixture: Fixture) {
        let classifier = ChatArtifactGalleryClassifier()

        #expect(classifier.filter(for: fixture.kind, path: fixture.path) == fixture.expected)
        #expect(classifier.systemImageName(for: fixture.kind, path: fixture.path) == fixture.expectedSystemImage)
    }
}
