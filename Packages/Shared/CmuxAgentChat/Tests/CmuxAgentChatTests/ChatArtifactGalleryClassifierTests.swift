import Testing

@testable import CmuxAgentChat

@Suite("Chat artifact gallery classifier")
struct ChatArtifactGalleryClassifierTests {
    struct Fixture: Sendable, CustomTestStringConvertible {
        let path: String
        let kind: ChatArtifactKind
        let expected: ChatArtifactGalleryFilter?

        var testDescription: String { "\(kind.rawValue):\(path)" }
    }

    @Test(arguments: [
        Fixture(path: "/tmp/photo.swift", kind: .image, expected: .images),
        Fixture(path: "/tmp/folder.png", kind: .directory, expected: .folders),
        Fixture(path: "/tmp/App.swift", kind: .text, expected: .code),
        Fixture(path: "/tmp/main.CPP", kind: .binary, expected: .code),
        Fixture(path: "/tmp/run.log", kind: .text, expected: .logs),
        Fixture(path: "/tmp/process.OUT", kind: .binary, expected: .logs),
        Fixture(path: "/tmp/notes.txt", kind: .text, expected: .logs),
        Fixture(path: "/tmp/README.md", kind: .text, expected: .docs),
        Fixture(path: "/tmp/report.PDF", kind: .binary, expected: .docs),
        Fixture(path: "/tmp/deck.pptx", kind: .binary, expected: .docs),
        Fixture(path: "/tmp/table.numbers", kind: .binary, expected: .docs),
        Fixture(path: "/tmp/archive.zip", kind: .binary, expected: nil),
        Fixture(path: "/tmp/LICENSE", kind: .text, expected: nil),
    ])
    func classifiesKindAndExtensionMatrix(_ fixture: Fixture) {
        let classifier = ChatArtifactGalleryClassifier()

        #expect(classifier.filter(for: fixture.kind, path: fixture.path) == fixture.expected)
    }
}
