import Foundation
import Testing

@testable import CmuxTerminal

@Suite("Terminal pasteboard temporary image adoption")
struct TerminalPasteboardTemporaryImageAdoptionTests {
    @Test("adoption preserves a validated image extension")
    func adoptionPreservesValidatedImageExtension() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-tests-image-adoption-\(UUID().uuidString)",
                isDirectory: true
            )
        let workerDirectory = scratchDirectory.appendingPathComponent(
            "worker",
            isDirectory: true
        )
        let ownedDirectory = scratchDirectory.appendingPathComponent(
            "owned",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workerDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: ownedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let source = workerDirectory.appendingPathComponent("prepared.svg")
        let sourceData = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8
        )
        try sourceData.write(to: source)
        let service = TerminalPasteboardService(
            temporaryDirectory: ownedDirectory
        )

        let adopted = try service.adoptTemporaryImageFile(
            source,
            from: workerDirectory
        )

        #expect(adopted.pathExtension == "svg")
        #expect(try Data(contentsOf: adopted) == sourceData)
    }

    @Test("permission failure restores the worker image")
    func permissionFailureRestoresWorkerImage() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-tests-image-adoption-permissions-\(UUID().uuidString)",
                isDirectory: true
            )
        let workerDirectory = scratchDirectory.appendingPathComponent(
            "worker",
            isDirectory: true
        )
        let ownedDirectory = scratchDirectory.appendingPathComponent(
            "owned",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workerDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: ownedDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let source = workerDirectory.appendingPathComponent("prepared.png")
        let sourceData = Data([0x89, 0x50, 0x4E, 0x47])
        try sourceData.write(to: source)
        let service = TerminalPasteboardService(
            temporaryDirectory: ownedDirectory,
            fileManager: TerminalPasteboardSetAttributesFailingFileManager()
        )

        #expect(throws: CocoaError(.fileWriteNoPermission)) {
            try service.adoptTemporaryImageFile(
                source,
                from: workerDirectory
            )
        }

        #expect(try Data(contentsOf: source) == sourceData)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: ownedDirectory.path
            ).isEmpty
        )
    }
}
