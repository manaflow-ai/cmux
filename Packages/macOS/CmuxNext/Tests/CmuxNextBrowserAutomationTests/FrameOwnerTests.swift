import CmuxNextBrowser
import Foundation
import Testing
import WebKit
@testable import CmuxNextBrowserAutomation

/// `frame.contentFrame` maps an `<iframe>` handle to the frame it holds,
/// and `frame.ownerBox` gives that iframe's content box in its parent's
/// viewport: what the runtime needs to enter a frame (`frameLocator`,
/// `contentFrame()`, snapshots and clicks inside frames). Frames created in
/// another order than the document's still map to their own iframe.
/// In DriverCallTests so every WebKit test runs serialized (DialogTests).
extension DriverCallTests {
    /// A page agent whose handles are element ids.
    static let frameAgent = """
    globalThis[Symbol.for("cmux.browserRepl.agent")] = {};
    globalThis.__cmuxPageAgent = { resolveHandle: (id) => document.getElementById(id) };
    """

    /// `c` is created last but sits first: frame creation order differs
    /// from document order.
    static let framesHTML = """
    <body style="margin:0">\
    <iframe id=a srcdoc="<body>A</body>" style="position:absolute;left:10px;top:20px;width:100px;height:50px;border:0"></iframe>\
    <iframe id=b srcdoc="<body>B</body>" style="position:absolute;left:200px;top:30px;width:120px;height:60px;border:3px solid;padding:2px"></iframe>\
    <p id=text>not a frame</p>\
    <script>const c = document.createElement("iframe"); c.id = "c"; c.srcdoc = "<body>C</body>"; document.body.insertBefore(c, document.getElementById("a"));</script>
    """
    static var framesPage: String { "data:text/html," + (framesHTML.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }

    @Test func anIframeHandleMapsToItsFrameAndItsContentBox() async throws {
        let provider = FakeProvider()
        let driver = WebKitDriver(provider: provider, agentBundle: Self.frameAgent)
        let opened = try await driver.call(method: "tabs.open", params: .object([:]))
        guard case .object(let fields) = opened, case .string(let id)? = fields["targetId"] else {
            Issue.record("tabs.open returned \(opened)")
            return
        }
        _ = try await driver.call(method: "tab.navigate", params: .object([
            "targetId": .string(id), "url": .string(Self.framesPage), "waitUntil": .string("load"), "timeoutMs": .number(15000),
        ]))
        func text(in frameId: String) async throws -> DriverJSON {
            try await driver.call(method: "frame.evaluate", params: .object([
                "targetId": .string(id), "frameId": .string(frameId), "world": .string("page"),
                "source": .string("() => document.body.textContent"), "args": .array([]),
            ]))
        }
        func contentFrame(_ element: String) async throws -> DriverJSON {
            try await driver.call(method: "frame.contentFrame", params: .object([
                "targetId": .string(id), "element": .string(element),
            ]))
        }
        for (element, body) in [("a", "A"), ("b", "B"), ("c", "C")] {
            guard case .object(let child) = try await contentFrame(element), case .string(let frameId)? = child["frameId"] else {
                Issue.record("frame.contentFrame(\(element)) found no frame")
                continue
            }
            #expect(try await text(in: frameId) == .string(body), "iframe \(element)")
            if element == "b" {
                let box = try await driver.call(method: "frame.ownerBox", params: .object([
                    "targetId": .string(id), "frameId": .string(frameId),
                ]))
                // 200 + 3 border + 2 padding, 30 + 3 + 2; the content box.
                #expect(box == .object(["x": .number(205), "y": .number(35), "width": .number(120), "height": .number(60)]))
            }
        }
        #expect(try await contentFrame("text") == .null, "not a frame owner")
        _ = try await driver.call(method: "tabs.close", params: .object(["targetId": .string(id)]))
    }
}
