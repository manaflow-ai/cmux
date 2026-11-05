// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import CoreGraphics
import Foundation
import ImageIO
import os
import Testing

@Suite struct PerceptionTests {
    /// A window screenshot: white, with boxes of `color` at `marks` (pixel rects).
    static func png(width: Int = 640, height: Int = 400, marks: [CGRect] = [],
                    color: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)) -> String {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(color)
        for mark in marks {
            // Top-left rects into CG's bottom-left space.
            context.fill(CGRect(x: mark.minX, y: CGFloat(height) - mark.maxY, width: mark.width, height: mark.height))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    static func windowState(_ png: String, elements: [[String: Any]] = []) -> Data {
        HelperWire.json([
            "content": [["type": "image", "mimeType": "image/png", "data": png],
                        ["type": "text", "text": "window_id=7 pid=1 size=640x400 elements=0"]],
            "structuredContent": ["window_id": 7, "pid": 1, "screenshot_width": 640, "screenshot_height": 400,
                                  "window_bounds": ["x": 0, "y": 0, "width": 320, "height": 200],
                                  "elements": elements] as [String: Any],
        ] as [String: Any])
    }

    /// Answers each call with the next queued result and records what it was sent.
    final class ScriptedTools: ToolInvoking, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock<[(String, [String: Any])]>(uncheckedState: [])
        let results = OSAllocatedUnfairLock<[Data]>(initialState: [])

        func queue(_ data: Data) { results.withLock { $0.append(data) } }
        func listTools() async throws -> Data { Data("{}".utf8) }
        func invoke(name: String, arguments: Data) async throws -> Data {
            let args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
            calls.withLockUnchecked { $0.append((name, args)) }
            return results.withLock { $0.isEmpty ? Data(#"{"content":[]}"#.utf8) : $0.removeFirst() }
        }
    }

    struct FixedOCR: TextRecognizing {
        func lines(in image: CGImage) throws -> [OCRLine] {
            let save = OCRWord(text: "Save", rect: PixelRect(x: 100, y: 50, width: 40, height: 14), confidence: 1)
            let all = OCRWord(text: "All", rect: PixelRect(x: 146, y: 50, width: 24, height: 14), confidence: 1)
            return [OCRLine(text: "Save All", rect: PixelRect(x: 100, y: 50, width: 70, height: 14), words: [save, all])]
        }
    }

    struct FixedZoom: ZoomCapturing {
        func capture(windowID: UInt32, region: PerceptionZoom.Region, frame: ScreenshotFrame) async throws
            -> (CGImage, ZoomMapping) {
            // Native: twice the screenshot's pixels for the region.
            let width = Int(region.pixels.width * 2), height = Int(region.pixels.height * 2)
            let image = PerceptionImage.decode(base64: PerceptionTests.png(width: width, height: height))!
            return (image, ZoomMapping(region: region.pixels, width: width, height: height))
        }
    }

    static func reply(_ data: Data) throws -> (content: [[String: Any]], structured: [String: Any]) {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (object["content"] as? [[String: Any]] ?? [], object["structuredContent"] as? [String: Any] ?? [:])
    }

    static func images(_ content: [[String: Any]]) -> [[String: Any]] {
        content.filter { $0["type"] as? String == "image" }
    }

    static let read = HelperWire.json(["pid": 1, "window_id": 7])

    @Test func anUnchangedScreenshotIsNotSentAgain() async throws {
        let tools = ScriptedTools()
        let perception = Perception(tools: tools, session: PerceptionSession())
        let shot = Self.png(marks: [CGRect(x: 10, y: 10, width: 50, height: 20)])
        tools.queue(Self.windowState(shot))
        tools.queue(Self.windowState(shot))
        tools.queue(Self.windowState(shot))
        let first = try Self.reply(try await perception.call(name: "get_window_state", arguments: Self.read))
        #expect(Self.images(first.content).count == 1)
        #expect((first.structured["perception"] as? [String: Any])?["screenshot"] as? String == "full")
        let second = try Self.reply(try await perception.call(name: "get_window_state", arguments: Self.read))
        #expect(Self.images(second.content).isEmpty)
        #expect(second.structured["screenshot_unchanged"] as? Bool == true)
        #expect(second.content.contains { ($0["text"] as? String)?.hasPrefix("Screenshot unchanged") == true })
        #expect(second.content.contains { ($0["text"] as? String)?.hasPrefix("window_id=7") == true },
                "the tree text still comes back")
        let forced = try Self.reply(try await perception.call(
            name: "get_window_state", arguments: HelperWire.json(["pid": 1, "window_id": 7, "force_screenshot": true])))
        #expect(Self.images(forced.content).count == 1)
        #expect(tools.calls.withLockUnchecked { $0.last?.1["force_screenshot"] } == nil,
                "the driver never sees this layer's arguments")
    }

    @Test func anotherConnectionGetsItsOwnFirstScreenshot() async throws {
        let tools = ScriptedTools()
        let shot = Self.png()
        tools.queue(Self.windowState(shot))
        tools.queue(Self.windowState(shot))
        _ = try await Perception(tools: tools, session: PerceptionSession()).call(name: "get_window_state", arguments: Self.read)
        let other = try Self.reply(try await Perception(tools: tools, session: PerceptionSession())
            .call(name: "get_window_state", arguments: Self.read))
        #expect(Self.images(other.content).count == 1)
    }

    @Test func aSmallChangeComesBackAsACropOfTheChangedRegion() async throws {
        let tools = ScriptedTools()
        let perception = Perception(tools: tools, session: PerceptionSession())
        tools.queue(Self.windowState(Self.png()))
        tools.queue(Self.windowState(Self.png(marks: [CGRect(x: 130, y: 70, width: 10, height: 10)])))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        let changed = try Self.reply(try await perception.call(name: "get_window_state", arguments: Self.read))
        let rect = try #require(changed.structured["screenshot_dirty_rect"] as? [String: Int])
        #expect(rect == ["x": 128, "y": 64, "w": 64, "h": 64], "the 64 px tile that holds the change")
        let image = try #require(Self.images(changed.content).first?["data"] as? String)
        let crop = try #require(PerceptionImage.decode(base64: image))
        #expect(crop.width == 64 && crop.height == 64)
    }

    @Test func aLargeChangeComesBackWhole() async throws {
        let tools = ScriptedTools()
        let perception = Perception(tools: tools, session: PerceptionSession())
        tools.queue(Self.windowState(Self.png()))
        tools.queue(Self.windowState(Self.png(marks: [CGRect(x: 0, y: 0, width: 640, height: 300)])))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        let changed = try Self.reply(try await perception.call(name: "get_window_state", arguments: Self.read))
        let image = try #require(Self.images(changed.content).first?["data"] as? String)
        #expect(PerceptionImage.decode(base64: image)?.width == 640)
        #expect(changed.structured["screenshot_dirty_rect"] == nil)
    }

    @Test func somModeAddsOCRWordBoxesAndElementText() async throws {
        let tools = ScriptedTools()
        var perception = Perception(tools: tools, session: PerceptionSession())
        perception.ocr = FixedOCR()
        let button: [String: Any] = ["element_index": 3, "role": "AXButton",
                                     "screenshot_frame": ["x": 90, "y": 40, "w": 60, "h": 30]]
        tools.queue(Self.windowState(Self.png(), elements: [button, ["element_index": 4]]))
        let reply = try Self.reply(try await perception.call(
            name: "get_window_state", arguments: HelperWire.json(["pid": 1, "window_id": 7, "capture_mode": "som"])))
        let sent = try #require(tools.calls.withLockUnchecked { $0.first?.1 })
        #expect(sent["capture_mode"] == nil && sent["ocr"] == nil)
        let text = reply.content.compactMap { $0["text"] as? String }.joined()
        #expect(text.contains("100,50 70x14: Save All | Save@100+40 All@146+24"))
        let elements = try #require(reply.structured["elements"] as? [[String: Any]])
        #expect(elements[0]["ocr_text"] as? String == "Save", "only the word whose centre is in the button")
        #expect(elements[1]["ocr_text"] == nil)
        #expect((reply.structured["ocr_lines"] as? [[String: Any]])?.count == 1)
    }

    @Test func zoomIsCapturedAgainAtNativeResolutionAndFromZoomIsTranslated() async throws {
        let tools = ScriptedTools()
        var perception = Perception(tools: tools, session: PerceptionSession())
        perception.zoomCapture = FixedZoom()
        tools.queue(Self.windowState(Self.png()))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        tools.queue(HelperWire.json([
            "content": [["type": "image", "mimeType": "image/jpeg", "data": Self.png(width: 50, height: 50)],
                        ["type": "text", "text": "Zoom region → 50×50 px JPEG."]],
            "structuredContent": ["width": 50, "height": 50, "format": "jpeg"],
        ] as [String: Any]))
        let zoom = try Self.reply(try await perception.call(
            name: "zoom", arguments: HelperWire.json(["window_id": 7, "x1": 100, "y1": 100, "x2": 200, "y2": 150])))
        // Region 100x50 padded by 20% each side: (80,90)-(220,160), 140x70; native is twice that.
        #expect(zoom.structured["width"] as? Int == 280)
        #expect(zoom.structured["native_resolution"] as? Bool == true)
        #expect(!zoom.content.contains { ($0["text"] as? String)?.contains("50×50") == true })
        tools.queue(Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8))
        _ = try await perception.call(name: "click", arguments: HelperWire.json(
            ["window_id": 7, "pid": 1, "x": 140, "y": 70, "from_zoom": true]))
        let click = try #require(tools.calls.withLockUnchecked { $0.last })
        #expect(click.0 == "click")
        #expect((click.1["x"] as? NSNumber)?.doubleValue == 150 && (click.1["y"] as? NSNumber)?.doubleValue == 125)
        #expect(click.1["from_zoom"] == nil)
    }

    @Test func aNewScreenshotEndsTheZoomTranslation() async throws {
        let tools = ScriptedTools()
        var perception = Perception(tools: tools, session: PerceptionSession())
        perception.zoomCapture = FixedZoom()
        tools.queue(Self.windowState(Self.png()))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        tools.queue(HelperWire.json(["content": [["type": "image", "mimeType": "image/jpeg", "data": Self.png(width: 50, height: 50)]]]))
        _ = try await perception.call(name: "zoom", arguments: HelperWire.json(["window_id": 7, "x1": 0, "y1": 0, "x2": 10, "y2": 10]))
        tools.queue(Self.windowState(Self.png()))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        let sent = HelperWire.json(["window_id": 7, "x": 1, "y": 2, "from_zoom": true])
        _ = try await perception.call(name: "click", arguments: sent)
        #expect(tools.calls.withLockUnchecked { $0.last?.1["from_zoom"] as? Bool } == true,
                "the driver answers from_zoom itself (zoom_context_missing)")
    }

    struct FailingZoom: ZoomCapturing {
        func capture(windowID: UInt32, region: PerceptionZoom.Region, frame: ScreenshotFrame) async throws
            -> (CGImage, ZoomMapping) { throw ToolError("no capture") }
    }

    static let driverZoom = HelperWire.json(["content": [["type": "image", "mimeType": "image/jpeg",
                                                         "data": PerceptionTests.png(width: 50, height: 50)]]])

    /// After a native zoom of window 7 (pid 1), a click with `from_zoom`.
    func clickAfterNativeZoom(_ click: [String: Any], zoomCapture: [any ZoomCapturing] = [FixedZoom()])
        async throws -> [String: Any] {
        let tools = ScriptedTools()
        let session = PerceptionSession()
        tools.queue(Self.windowState(Self.png()))
        _ = try await Perception(tools: tools, session: session).call(name: "get_window_state", arguments: Self.read)
        for capture in zoomCapture {
            var perception = Perception(tools: tools, session: session)
            perception.zoomCapture = capture
            tools.queue(Self.driverZoom)
            _ = try await perception.call(name: "zoom", arguments: HelperWire.json(
                ["window_id": 7, "x1": 100, "y1": 100, "x2": 200, "y2": 150]))
        }
        tools.queue(Data(#"{"content":[]}"#.utf8))
        _ = try await Perception(tools: tools, session: session).call(name: "click", arguments: HelperWire.json(click))
        return try #require(tools.calls.withLockUnchecked { $0.last?.1 })
    }

    @Test func aPidOnlyFromZoomClickIsTranslatedToo() async throws {
        let sent = try await clickAfterNativeZoom(["pid": 1, "x": 140, "y": 70, "from_zoom": true])
        #expect((sent["x"] as? NSNumber)?.doubleValue == 150 && sent["from_zoom"] == nil)
        let other = try await clickAfterNativeZoom(["pid": 2, "x": 140, "y": 70, "from_zoom": true])
        #expect(other["from_zoom"] as? Bool == true, "another app's click is the driver's to answer")
    }

    @Test func aFailedNativeZoomEndsTheEarlierOnesTranslation() async throws {
        let sent = try await clickAfterNativeZoom(["window_id": 7, "x": 10, "y": 10, "from_zoom": true],
                                                  zoomCapture: [FixedZoom(), FailingZoom()])
        #expect(sent["from_zoom"] as? Bool == true && (sent["x"] as? NSNumber)?.doubleValue == 10,
                "the driver's own crop is what the agent sees, so the driver translates")
    }

    @Test func aBypassedReadEndsUnchanged() async throws {
        let tools = ScriptedTools()
        let perception = Perception(tools: tools, session: PerceptionSession())
        let shot = Self.png()
        tools.queue(Self.windowState(shot))
        tools.queue(Self.windowState(Self.png(marks: [CGRect(x: 0, y: 0, width: 300, height: 300)])))
        tools.queue(Self.windowState(shot))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        _ = try await perception.call(name: "get_window_state",
                                      arguments: HelperWire.json(["pid": 1, "window_id": 7, "perception": false]))
        let after = try Self.reply(try await perception.call(name: "get_window_state", arguments: Self.read))
        #expect(Self.images(after.content).count == 1, "the agent last saw the bypassed image, not this one")
        #expect(tools.calls.withLockUnchecked { $0[1].1["perception"] } == nil)
    }

    @Test func aColourOnlyChangeIsAChange() async throws {
        let tools = ScriptedTools()
        let perception = Perception(tools: tools, session: PerceptionSession())
        let dot = [CGRect(x: 300, y: 200, width: 12, height: 12)]
        // Red and green of about the same brightness.
        tools.queue(Self.windowState(Self.png(marks: dot, color: CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1))))
        tools.queue(Self.windowState(Self.png(marks: dot, color: CGColor(red: 0.3, green: 0.62, blue: 0.3, alpha: 1))))
        _ = try await perception.call(name: "get_window_state", arguments: Self.read)
        let after = try Self.reply(try await perception.call(name: "get_window_state", arguments: Self.read))
        #expect(after.structured["screenshot_unchanged"] == nil)
        #expect(after.structured["screenshot_dirty_rect"] as? [String: Int] == ["x": 256, "y": 192, "w": 64, "h": 64])
    }

    @Test func afterACropTheBaselineIsWhatTheAgentHas() throws {
        let plain = try #require(PerceptionImage.decode(base64: Self.png()))
        let a = try #require(ScreenSignature(image: plain))
        let markedImage = try #require(PerceptionImage.decode(base64: Self.png(marks: [
            CGRect(x: 10, y: 10, width: 10, height: 10), CGRect(x: 500, y: 300, width: 10, height: 10)])))
        let b = try #require(ScreenSignature(image: markedImage))
        let shown = PixelRect(x: 0, y: 0, width: 64, height: 64)
        let baseline = a.replacing(shown, from: b)
        #expect(b.change(since: baseline)?.rect == PixelRect(x: 448, y: 256, width: 64, height: 64),
                "the change outside the crop is still unseen")
    }

    @Test func zoomPlanIsInWindowPointsAtTheDisplayScale() {
        let frame = ScreenshotFrame(width: 1366, height: 880, windowWidth: 1440, windowHeight: 927.7)
        let region = PerceptionZoom.Region(pixels: CGRect(x: 100, y: 200, width: 300, height: 30))
        let plan = PerceptionZoom.plan(region, frame: frame, pointPixelScale: 2)
        let k = 1440.0 / 1366.0
        #expect(abs(plan.source.minX - 100 * k) < 1e-9 && abs(plan.source.width - 300 * k) < 1e-9)
        #expect(plan.width == Int((300 * k * 2).rounded()) && plan.height == Int((30 * k * 2).rounded()))
        let wide = PerceptionZoom.plan(PerceptionZoom.Region(pixels: CGRect(x: 0, y: 0, width: 1366, height: 100)),
                                       frame: frame, pointPixelScale: 2)
        #expect(wide.width == PerceptionZoom.maxLongEdge, "capped at the model's image limit")
        let mapping = ZoomMapping(region: region.pixels, width: plan.width, height: plan.height)
        let corner = mapping.screenshotPoint(x: Double(plan.width), y: Double(plan.height))
        #expect(abs(corner.x - 400) < 1e-9 && abs(corner.y - 230) < 1e-9)
    }

    @Test func otherCallsReachTheDriverByteForByte() async throws {
        final class Recorder: ToolInvoking, @unchecked Sendable {
            let sent = OSAllocatedUnfairLock<Data?>(initialState: nil)
            func listTools() async throws -> Data { Data() }
            func invoke(name: String, arguments: Data) async throws -> Data {
                sent.withLock { $0 = arguments }
                return Data("{}".utf8)
            }
        }
        let recorder = Recorder()
        let arguments = Data(#"{"x": 1.0, "y": 2.50, "pid": 3}"#.utf8)
        _ = try await Perception(tools: recorder, session: PerceptionSession()).call(name: "click", arguments: arguments)
        #expect(recorder.sent.withLock { $0 } == arguments)
    }

    @Test func theToolListNamesThisLayersArgumentsAndTheRealZoomSize() throws {
        let listed = HelperWire.json(["tools": [
            ["name": "get_window_state", "inputSchema": ["type": "object", "properties": [
                "capture_mode": ["type": "string", "enum": ["ax", "vision"]]]]],
            ["name": "zoom", "description": "Crop. The output image is at most 500 px wide. More."],
        ] as [[String: Any]]])
        let root = try #require(try JSONSerialization.jsonObject(with: Perception.listing(listed)) as? [String: Any])
        let tools = try #require(root["tools"] as? [[String: Any]])
        let properties = try #require((tools[0]["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])
        #expect(properties["ocr"] != nil && properties["force_screenshot"] != nil && properties["perception"] != nil)
        #expect((properties["capture_mode"] as? [String: Any])?["enum"] as? [String] == ["ax", "vision", "som"])
        #expect((tools[1]["description"] as? String)?.contains("native resolution") == true)
    }

    @Test func signatureFindsTheDirtyTile() throws {
        let base = try #require(PerceptionImage.decode(base64: Self.png()))
        let marked = try #require(PerceptionImage.decode(base64: Self.png(marks: [CGRect(x: 600, y: 390, width: 4, height: 4)])))
        let a = try #require(ScreenSignature(image: base)), b = try #require(ScreenSignature(image: marked))
        #expect(a.change(since: a) == ScreenSignature.Change(rect: nil, dirtyTiles: 0))
        #expect(b.change(since: a)?.rect == PixelRect(x: 576, y: 384, width: 64, height: 16), "clamped to the screenshot")
        let narrow = try #require(PerceptionImage.decode(base64: Self.png(width: 320)))
        let smaller = try #require(ScreenSignature(image: narrow))
        #expect(smaller.change(since: a) == nil, "another size cannot be compared")
    }

    @Test func zoomRegionIsPaddedAndClamped() {
        let frame = ScreenshotFrame(width: 640, height: 400, windowWidth: 320, windowHeight: 200)
        #expect(PerceptionZoom.region(["x1": 0, "y1": 0, "x2": 100, "y2": 100], frame: frame)?.pixels
                == CGRect(x: 0, y: 0, width: 120, height: 120))
        #expect(PerceptionZoom.region(["x": 600, "y": 380, "width": 40, "height": 20], frame: frame)?.pixels
                == CGRect(x: 592, y: 376, width: 48, height: 24))
        #expect(PerceptionZoom.region(["x1": 5, "y1": 5, "x2": 5, "y2": 9], frame: frame) == nil)
    }

    @Test func ocrWordRangesSplitOnWhitespace() {
        let text = "  File  Edit\tView "
        #expect(PerceptionOCR.wordRanges(text).map { String(text[$0]) } == ["File", "Edit", "View"])
        #expect(PerceptionOCR.pixels(CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25), width: 400, height: 200)
                == PixelRect(x: 200, y: 0, width: 100, height: 50))
    }
}
