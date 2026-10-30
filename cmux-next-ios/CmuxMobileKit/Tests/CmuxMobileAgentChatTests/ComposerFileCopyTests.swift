import CmuxMobileDesign
import Foundation
import Testing

@Suite struct ComposerFileCopyTests {
    @Test func providerFileSurvivesSourceRemovalWithoutLoadingItWhole() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("attachment.bin")
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let writer = try FileHandle(forWritingTo: source)
        let size = 101 * 1024 * 1024 + 7
        try writer.truncate(atOffset: UInt64(size))
        try writer.seek(toOffset: UInt64(size - 4))
        try writer.write(contentsOf: Data([1, 2, 3, 4]))
        try writer.close()
        let copy = try ComposerFileCopy(source: source)
        defer { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: source)
        #expect(copy.byteCount == size)
        #expect(copy.inlineData == nil)
        let reader = try FileHandle(forReadingFrom: copy.url)
        defer { try? reader.close() }
        #expect(try reader.seekToEnd() == UInt64(size))
        try reader.seek(toOffset: UInt64(size - 4))
        #expect(try reader.read(upToCount: 4) == Data([1, 2, 3, 4]))
    }

    @Test func smallTextAndEmptyFilesRemainAttachable() throws {
        for bytes in [Data("hello".utf8), Data()] {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let copy = try ComposerFileCopy(source: source)
            defer { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }
            #expect(copy.inlineData == bytes)
            #expect(copy.byteCount == bytes.count)
        }
    }
}
