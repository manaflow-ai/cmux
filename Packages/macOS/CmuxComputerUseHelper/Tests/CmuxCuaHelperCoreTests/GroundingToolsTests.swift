// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import os
import Testing

@Suite struct GroundingToolsTests {
    /// The driver: answers get_window_state with `elements` and a 1000x500 screenshot, records every call.
    final class Driver: ToolInvoking, @unchecked Sendable {
        let elements: [[String: Any]]
        let degraded: Bool
        let listing: Any
        let raw = OSAllocatedUnfairLock<[(String, Data)]>(initialState: [])

        /// Every call so far: the tool's name and its decoded arguments.
        var calls: [(String, [String: Any])] {
            raw.withLock { $0 }.map { ($0.0, (try? JSONSerialization.jsonObject(with: $0.1)) as? [String: Any] ?? [:]) }
        }

        init(elements: [[String: Any]], degraded: Bool = false,
             listing: Any = ["tools": [["name": "click"], ["name": "get_window_state"]]]) {
            self.elements = elements
            self.degraded = degraded
            self.listing = listing
        }

        func listTools() async throws -> Data { try JSONSerialization.data(withJSONObject: listing) }

        func invoke(name: String, arguments: Data) async throws -> Data {
            raw.withLock { $0.append((name, arguments)) }
            guard name == "get_window_state" else { return Data(#"{"ok":true}"#.utf8) }
            var structured: [String: Any] = ["elements": elements, "screenshot_width": 1000, "screenshot_height": 500,
                                             "capture_id": "cap-1"]
            if degraded { structured["degraded_reason"] = "ax_window_unresolved" }
            return try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "state"],
                            ["type": "image", "mimeType": "image/png", "data": Data("png".utf8).base64EncodedString()]],
                "structuredContent": structured,
            ])
        }
    }

    final class Model: GroundingLocating, @unchecked Sendable {
        let asked = OSAllocatedUnfairLock<[(Int, Int, String)]>(initialState: [])
        var answer = (x: 250.4, y: 120.6)
        func locate(png: Data, width: Int, height: Int, description: String) async throws -> GroundingAnswer {
            asked.withLock { $0.append((width, height, description)) }
            return GroundingAnswer(x: answer.x, y: answer.y, model: "holo-3.1-4b", milliseconds: 42)
        }
    }

    static func named(_ count: Int) -> [[String: Any]] {
        (0..<count).map { ["element_index": $0, "role": "AXButton", "label": "Tool \($0)"] }
    }

    static func call(_ tools: GroundingTools, _ description: String) async throws -> [String: Any] {
        let data = try await tools.invoke(name: GroundingTools.toolName, arguments: JSONSerialization.data(
            withJSONObject: ["pid": 42, "window_id": 7, "description": description, "session": "s"]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["structuredContent"] as? [String: Any])
    }

    @Test func thinTreeAsksTheModelForAPointOnTheScreenshot() async throws {
        let driver = Driver(elements: Self.named(3) + [["role": "AXGroup", "element_index": 9]])
        let model = Model()
        let result = try await Self.call(GroundingTools(inner: driver, model: model), "the brush size slider")
        #expect(result["source"] as? String == "grounding")
        #expect(result["x"] as? Double == 250 && result["y"] as? Double == 121)
        #expect(result["capture_id"] as? String == "cap-1")
        #expect(model.asked.withLock { $0.map(\.2) } == ["the brush size slider"])
        #expect(model.asked.withLock { $0.first.map { [$0.0, $0.1] } } == [1000, 500])
        // One observation through the driver (so its target guard and consent check run), never an action.
        let calls = driver.calls
        #expect(calls.map(\.0) == ["get_window_state"])
        #expect(calls.first?.1["pid"] as? Int == 42 && calls.first?.1["window_id"] as? Int == 7)
        #expect(calls.first?.1["session"] as? String == "s")
    }

    @Test func aDegradedWalkIsThinWhateverItHolds() async throws {
        let model = Model()
        let result = try await Self.call(GroundingTools(inner: Driver(elements: Self.named(40), degraded: true), model: model),
                                         "the canvas")
        #expect(result["source"] as? String == "grounding")
    }

    @Test func aLabelHoldingEveryWordAnswersFromTheTree() async throws {
        let elements = Self.named(2) + [["element_index": 5, "label": "Export Selection", "element_token": "t5",
                                         "frame": ["x": 1, "y": 2, "w": 3, "h": 4]]]
        let model = Model()
        let result = try await Self.call(GroundingTools(inner: Driver(elements: elements), model: model),
                                         "the Export selection button")
        #expect(result["source"] as? String == "ax")
        #expect(result["element_index"] as? Int == 5 && result["element_token"] as? String == "t5")
        #expect(model.asked.withLock { $0.isEmpty })
    }

    @Test func aFullTreeWithNoMatchSendsNoScreenshot() async throws {
        let model = Model()
        let result = try await Self.call(GroundingTools(inner: Driver(elements: Self.named(30)), model: model), "Tool zebra")
        #expect(result["source"] as? String == "none")
        #expect((result["closest"] as? [[String: Any]])?.isEmpty == false)
        #expect(model.asked.withLock { $0.isEmpty })
    }

    @Test func aPointOffTheScreenshotIsClampedIntoIt() async throws {
        let model = Model()
        model.answer = (x: 5000, y: -3)
        let result = try await Self.call(GroundingTools(inner: Driver(elements: []), model: model), "play")
        #expect(result["x"] as? Double == 999 && result["y"] as? Double == 0)
    }

    @Test func otherToolsPassThroughUnchanged() async throws {
        let driver = Driver(elements: [])
        let tools = GroundingTools(inner: driver, model: Model())
        let data = try await tools.invoke(name: "click", arguments: Data(#"{"pid":1}"#.utf8))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(driver.calls.map(\.0) == ["click"])
    }

    @Test func aMissingDescriptionIsRefused() async {
        await #expect(throws: ToolError.self) {
            _ = try await GroundingTools(inner: Driver(elements: []), model: Model())
                .invoke(name: GroundingTools.toolName, arguments: Data(#"{"pid":1,"window_id":2,"description":" "}"#.utf8))
        }
    }

    @Test(arguments: [true, false])
    func theToolIsListedOnceAsReadOnly(bareArray: Bool) async throws {
        let listing: Any = bareArray ? [["name": "click"], ["name": GroundingTools.toolName]]
            : ["tools": [["name": "click"], ["name": GroundingTools.toolName]]]
        let data = try await GroundingTools(inner: Driver(elements: [], listing: listing), model: Model()).listTools()
        let object = try JSONSerialization.jsonObject(with: data)
        let tools = try #require((bareArray ? object : (object as? [String: Any])?["tools"]) as? [[String: Any]])
        let ours = tools.filter { $0["name"] as? String == GroundingTools.toolName }
        #expect(ours.count == 1)
        #expect((ours.first?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        #expect(tools.count == 2)
    }
}

@Suite struct GroundingModelTests {
    @Test func smartResizeMatchesQwen() {
        let size = GroundingFamily.smartResize(height: 1440, width: 2560, factor: 28, minPixels: 3136, maxPixels: 12_845_056)
        #expect(size.height == 1428 && size.width == 2548)
        let down = GroundingFamily.smartResize(height: 2880, width: 5120, factor: 28, minPixels: 3136, maxPixels: 4_800_000)
        #expect(down.height * down.width <= 4_800_000)
    }

    @Test func holoAnswersInThousandths() throws {
        let point = try #require(GroundingFamily.holo.point(in: #"<think>x: 9</think>{"x": 500, "y": 250}"#, width: 2000, height: 1000))
        #expect(point.x == 1000 && point.y == 250)
    }

    @Test func absoluteFamiliesMapBackFromTheResizedImage() throws {
        // A 2560x1440 screenshot is resized to 2548x1428 for OpenCUA; its answer maps back up.
        let point = try #require(GroundingFamily.opencua.point(in: "pyautogui.click(x=1274, y=714)", width: 2560, height: 1440))
        #expect(abs(point.x - 1280) < 0.01 && abs(point.y - 720) < 0.01)
        let venus = try #require(GroundingFamily.venus.point(in: "[100,200,300,400]", width: 1000, height: 1000))
        let resized = GroundingFamily.venus.resized(width: 1000, height: 1000)
        #expect(abs(venus.x - 200 * 1000 / Double(resized.width)) < 0.01)
        #expect(GroundingFamily.gta1.point(in: "(10,20)", width: 1000, height: 1000) != nil)
        #expect(GroundingFamily.holo.point(in: "no idea", width: 10, height: 10) == nil)
    }

    @Test func familyComesFromTheServedName() {
        #expect(GroundingFamily(modelName: "xlangai/OpenCUA-7B") == .opencua)
        #expect(GroundingFamily(modelName: "/cache/ui-venus-ground-7b-bf16") == .venus)
        #expect(GroundingFamily(modelName: "gta1-7b") == .gta1)
        #expect(GroundingFamily(modelName: "holo-3.1-4b") == .holo)
    }

    @Test(arguments: [
        ("http://127.0.0.1:8080/v1", true), ("http://localhost:8080/v1", true), ("https://gpu.example.ts.net/v1", true),
        ("http://gpu.example.ts.net/v1", false), ("https://user:pw@host/v1", false), ("ftp://127.0.0.1/v1", false), ("", false),
    ])
    func onlyLoopbackMayBePlainHTTP(endpoint: String, accepted: Bool) {
        #expect((GroundingConfig(environment: [GroundingConfig.endpointKey: endpoint]) != nil) == accepted)
    }

    @Test func noEndpointMeansNoFallback() {
        #expect(GroundingConfig(environment: [:]) == nil)
    }
}
