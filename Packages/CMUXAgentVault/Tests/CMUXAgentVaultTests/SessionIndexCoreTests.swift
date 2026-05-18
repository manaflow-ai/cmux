import XCTest
@testable import CMUXAgentVault

final class SessionIndexCoreTests: XCTestCase {
    func testForEachJSONLineStopsAfterRequestedObject() throws {
        let fixture = try makeTempFile(contents: """
        {"id":"first","title":"One"}
        {"id":"second","title":"Two"}
        {"id":"third","title":"Three"}
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var ids: [String] = []
        SessionIndexCore.forEachJSONLine(url: fixture.file, maxBytes: 1024) { object in
            ids.append(object["id"] as? String ?? "")
            return ids.count == 2
        }

        XCTAssertEqual(ids, ["first", "second"])
    }

    func testForEachJSONLineDoesNotParseBeyondMaxBytes() throws {
        let firstLine = #"{"id":"first","title":"One"}"# + "\n"
        let secondLine = #"{"id":"second","title":"Two"}"# + "\n"
        let fixture = try makeTempFile(contents: firstLine + secondLine)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var ids: [String] = []
        SessionIndexCore.forEachJSONLine(url: fixture.file, maxBytes: firstLine.utf8.count) { object in
            ids.append(object["id"] as? String ?? "")
            return false
        }

        XCTAssertEqual(ids, ["first"])
    }

    func testReadFileHeadAndTailRespectByteCapsAndLineBoundary() throws {
        let fixture = try makeTempFile(contents: """
        line-1
        line-2
        line-3
        line-4
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(SessionIndexCore.readFileHead(url: fixture.file, byteCap: 6), "line-1")
        XCTAssertEqual(SessionIndexCore.readFileTail(url: fixture.file, byteCap: 16), "line-3\nline-4\n")
    }

    func testFileContainsNeedleScansAcrossChunksCaseInsensitively() throws {
        let needle = "Needle Across Large File"
        let chunkSize = 64 * 1024
        // Place the needle across the chunk boundary used by fileContainsNeedle.
        let prefix = String(repeating: "a", count: chunkSize - needle.utf8.count / 2)
        let suffix = String(repeating: "b", count: 70 * 1024)
        let fixture = try makeTempFile(contents: prefix + needle + suffix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertTrue(SessionIndexCore.fileContainsNeedle(url: fixture.file, needle: "needle across"))
        XCTAssertFalse(SessionIndexCore.fileContainsNeedle(url: fixture.file, needle: "not present"))
    }

    private func makeTempFile(contents: String) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-index-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl", isDirectory: false)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return (directory, file)
    }
}
