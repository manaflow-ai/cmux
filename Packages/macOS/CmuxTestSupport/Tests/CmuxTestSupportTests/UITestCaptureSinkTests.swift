import Foundation
import Testing
@testable import CmuxTestSupport

@Suite("UITestCaptureSink")
struct UITestCaptureSinkTests {
    private func makeScratchPath(_ name: String = "capture.txt") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-support-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    @Test func unconfiguredEnvironmentIsANoOp() {
        let sink = UITestCaptureSink(environment: [:])
        #expect(!sink.appendLineIfConfigured(envKey: "CMUX_UI_TEST_X", line: "hello"))
        #expect(!sink.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_X") { $0["k"] = 1 })
    }

    @Test func blankOrWhitespacePathIsANoOp() {
        let sink = UITestCaptureSink(environment: ["CMUX_UI_TEST_X": "  \n "])
        #expect(!sink.appendLineIfConfigured(envKey: "CMUX_UI_TEST_X", line: "hello"))
    }

    @Test func appendCreatesParentDirectoryAndAppendsLines() throws {
        let url = makeScratchPath()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sink = UITestCaptureSink(environment: ["CMUX_UI_TEST_X": url.path])

        #expect(sink.appendLineIfConfigured(envKey: "CMUX_UI_TEST_X", line: "first"))
        #expect(sink.appendLineIfConfigured(envKey: "CMUX_UI_TEST_X", line: "second"))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "first\nsecond\n")
    }

    @Test func mutateJSONMergesIntoExistingObject() throws {
        let url = makeScratchPath("capture.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sink = UITestCaptureSink(environment: ["CMUX_UI_TEST_X": url.path])

        #expect(sink.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_X") { payload in
            payload["b"] = 2
        })
        #expect(sink.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_X") { payload in
            payload["a"] = 1
        })

        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        #expect(object?["a"] as? Int == 1)
        #expect(object?["b"] as? Int == 2)
        // Sorted keys are part of the on-disk format XCUITest asserts on.
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).hasPrefix("{\"a\":1"))
    }

    @Test func mutateJSONReplacesUnparsableFile() throws {
        let url = makeScratchPath("capture.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: url)
        let sink = UITestCaptureSink(environment: ["CMUX_UI_TEST_X": url.path])

        #expect(sink.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_X") { payload in
            payload["k"] = "v"
        })

        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        #expect(object?["k"] as? String == "v")
    }
}
