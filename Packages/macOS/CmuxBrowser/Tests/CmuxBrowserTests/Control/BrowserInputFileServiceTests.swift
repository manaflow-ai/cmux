import Darwin
import Foundation
import Testing
@testable import CmuxBrowser

struct BrowserInputFileServiceTests {
    @Test
    func preservesBinaryContentAndOmitsParentPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("statement 日本語.csv")
        let bytes = Data([0, 127, 128, 255, 10])
        try bytes.write(to: file)
        let json = try await BrowserInputFileService().prepare(paths: [file.path]).get()
        let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let item = try #require(payload.first)
        #expect(item["name"] as? String == file.lastPathComponent)
        #expect(Data(base64Encoded: try #require(item["base64"] as? String)) == bytes)
        #expect(item["type"] as? String == "text/csv")
        #expect(!json.contains(directory.path))
        #expect(try await BrowserInputFileService().prepare(paths: []).get() == "[]")
    }

    @Test
    func rejectsOversizeSelectionsAndNonregularFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.bin")
        try Data([1, 2, 3]).write(to: file)
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let service = BrowserInputFileService(maximumBytes: 5, maximumFiles: 2)
        #expect(try await service.prepare(paths: [file.path]).get().contains("AQID"))
        for paths in [[file.path, file.path], [fifo.path], [directory.path], ["relative.csv"],
                      [file.path, file.path, file.path], [directory.appendingPathComponent("missing").path]] {
            guard case .failure = await service.prepare(paths: paths) else {
                Issue.record("Expected rejection for \(paths)")
                continue
            }
        }
    }
}
