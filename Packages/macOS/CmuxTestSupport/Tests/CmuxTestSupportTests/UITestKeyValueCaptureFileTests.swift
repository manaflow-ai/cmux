import Foundation
import Testing
@testable import CmuxTestSupport

@Suite("UITestKeyValueCaptureFile")
struct UITestKeyValueCaptureFileTests {
    private func makeScratchPath(_ name: String = "capture.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-support-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test func loadReturnsEmptyForMissingFile() {
        let url = makeScratchPath()
        let file = UITestKeyValueCaptureFile(path: url.path)
        #expect(file.load().isEmpty)
    }

    @Test func loadReturnsEmptyForUnparsableFile() throws {
        let url = makeScratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)

        let file = UITestKeyValueCaptureFile(path: url.path)
        #expect(file.load().isEmpty)
    }

    @Test func mergeAccumulatesAcrossWritesAndOverwritesKeys() throws {
        let url = makeScratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = UITestKeyValueCaptureFile(path: url.path)

        file.merge(["a": "1", "b": "2"])
        file.merge(["b": "3", "c": "4"])

        #expect(file.load() == ["a": "1", "b": "3", "c": "4"])
    }

    @Test func mergeWritesUnsortedKeysByteFaithfully() throws {
        // The legacy inline writer serialized with no options (unsorted keys).
        // Pin that the package writer produces the same bytes a manual
        // JSONSerialization.data(withJSONObject:) merge would, so the on-disk
        // format the XCUITest harness reads is unchanged.
        let url = makeScratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let file = UITestKeyValueCaptureFile(path: url.path)

        let updates = ["windowRouteStatus": "1", "windowRouteFailure": ""]
        file.merge(updates)

        let onDisk = try Data(contentsOf: url)
        let expected = try JSONSerialization.data(withJSONObject: updates)
        #expect(onDisk == expected)
    }

    @Test func mergeOntoExistingParsableFile() throws {
        let url = makeScratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: ["seed": "x"]).write(to: url)

        let file = UITestKeyValueCaptureFile(path: url.path)
        file.merge(["seed": "y", "new": "z"])

        #expect(file.load() == ["seed": "y", "new": "z"])
    }
}
