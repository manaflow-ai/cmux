// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCUEngine
import CoreGraphics
import Foundation
import Testing

@Suite struct KeySpecTests {
    @Test func namedKeysAndChords() throws {
        #expect(try KeySpec(parsing: "Return") == KeySpec(keyCode: 36))
        #expect(try KeySpec(parsing: "super+c") == KeySpec(keyCode: 8, flags: .maskCommand))
        #expect(try KeySpec(parsing: "ctrl+shift+Tab") == KeySpec(keyCode: 48, flags: [.maskControl, .maskShift]))
        #expect(try KeySpec(parsing: "KP_0") == KeySpec(keyCode: 82))
        #expect(try KeySpec(parsing: "cmd++") == KeySpec(keyCode: 24, flags: .maskCommand))
    }

    @Test func charactersCarryTheirShift() throws {
        #expect(try KeySpec(parsing: "A") == KeySpec(keyCode: 0, flags: .maskShift))
        #expect(try KeySpec(parsing: "?") == KeySpec(keyCode: 44, flags: .maskShift))
        #expect(try KeySpec(parsing: "7") == KeySpec(keyCode: 26))
    }

    @Test func unknownNamesAreRefusedWithTheirName() {
        #expect(throws: KeySpec.ParseError.unknownKey("Banana")) { try KeySpec(parsing: "Banana") }
        #expect(throws: KeySpec.ParseError.unknownModifier("hyper")) { try KeySpec(parsing: "hyper+a") }
        #expect(throws: KeySpec.ParseError.empty) { try KeySpec(parsing: "") }
    }
}

@Suite struct SettlePolicyTests {
    let policy = SettlePolicy(quiet: .milliseconds(40), idleFloor: .milliseconds(60), ceiling: .milliseconds(600))

    @Test func waitsUntilQuietAfterTheLastEvent() {
        #expect(policy.outcome(elapsed: .milliseconds(30), sinceLastEvent: .milliseconds(10)) == nil)
        #expect(policy.outcome(elapsed: .milliseconds(80), sinceLastEvent: .milliseconds(40)) == .quiet)
    }

    @Test func anAppThatSaysNothingEndsAtTheIdleFloor() {
        #expect(policy.outcome(elapsed: .milliseconds(59), sinceLastEvent: nil) == nil)
        #expect(policy.outcome(elapsed: .milliseconds(60), sinceLastEvent: nil) == .idle)
    }

    @Test func aBusyAppEndsAtTheCeiling() {
        #expect(policy.outcome(elapsed: .milliseconds(600), sinceLastEvent: .milliseconds(1)) == .ceiling)
    }
}

@Suite struct VisualSettlePolicyTests {
    let policy = VisualSettlePolicy(visualQuiet: .milliseconds(48), visualIdle: .milliseconds(100),
                                    axQuiet: .milliseconds(32), ceiling: .milliseconds(800))

    @Test func aDrawnChangeSettlesOnceTheWindowStopsDrawing() {
        #expect(policy.outcome(elapsed: .milliseconds(60), sinceFrame: .milliseconds(10), sinceAX: nil) == nil)
        #expect(policy.outcome(elapsed: .milliseconds(90), sinceFrame: .milliseconds(48), sinceAX: nil) == .quiet)
    }

    @Test func noFrameAtAllMeansNothingVisibleChanged() {
        #expect(policy.outcome(elapsed: .milliseconds(99), sinceFrame: nil, sinceAX: nil) == nil)
        #expect(policy.outcome(elapsed: .milliseconds(100), sinceFrame: nil, sinceAX: nil) == .idle)
    }

    @Test func recentAccessibilityNotificationsHoldTheWait() {
        #expect(policy.outcome(elapsed: .milliseconds(200), sinceFrame: .milliseconds(100), sinceAX: .milliseconds(5)) == nil)
        #expect(policy.outcome(elapsed: .milliseconds(200), sinceFrame: .milliseconds(100), sinceAX: .milliseconds(40)) == .quiet)
    }

    @Test func anAnimatingWindowEndsAtTheCeiling() {
        #expect(policy.outcome(elapsed: .milliseconds(800), sinceFrame: .milliseconds(1), sinceAX: .milliseconds(1)) == .ceiling)
    }
}

@Suite struct GeometryTests {
    @Test func retinaWindowKeepsTwoPixelsPerPoint() {
        let geometry = ScreenshotGeometry(windowFrame: CGRect(x: 100, y: 50, width: 230, height: 408),
                                          displayScale: 2, maxLongEdge: 1568)
        #expect(geometry.pixelWidth == 460)
        #expect(geometry.pixelHeight == 816)
        #expect(geometry.globalPoint(x: 460, y: 816) == CGPoint(x: 330, y: 458))
    }

    @Test func aLargeWindowIsCappedOnItsLongEdge() {
        let geometry = ScreenshotGeometry(windowFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                          displayScale: 2, maxLongEdge: 1568)
        #expect(geometry.pixelWidth == 1568)
        #expect(geometry.pixelHeight == 980)
        // A pixel maps back to the point it shows.
        let corner = geometry.globalPoint(x: 1568, y: 980)
        #expect(abs(corner.x - 1600) < 0.001 && abs(corner.y - 1000) < 0.001)
    }
}

@Suite struct TreeRendererTests {
    @Test func linesReadLikeCodexComputerUse() {
        var button = AXNodeInfo()
        button.role = "AXButton"
        button.roleDescription = "button"
        button.label = "7"
        button.identifier = "Seven"
        button.actions = ["AXPress"]
        button.depth = 2
        #expect(TreeRenderer().line(index: 10, button) == "\t\t10 button Description: 7, ID: Seven")

        var window = AXNodeInfo()
        window.roleDescription = "standard window"
        window.title = "Calculator"
        window.identifier = "main"
        window.actions = ["AXRaise"]
        #expect(TreeRenderer().line(index: 0, window) == "0 standard window Calculator, ID: main, Secondary Actions: Raise")
    }

    @Test func flagsAndLongValues() {
        var field = AXNodeInfo()
        field.roleDescription = "text field"
        field.value = String(repeating: "x", count: 400)
        field.valueSettable = true
        field.focused = true
        let line = TreeRenderer(maxValueLength: 10).line(index: 3, field)
        #expect(line == "3 text field (focused, settable) Value: xxxxxxxxxx…")
    }

    @Test func secondaryActionNamesMapBack() {
        var info = AXNodeInfo()
        info.actions = ["AXPress", "AXShowMenu", "AXIncrement"]
        #expect(TreeRenderer.axAction(named: "Show Menu", in: info) == "AXShowMenu")
        #expect(TreeRenderer.axAction(named: "increment", in: info) == "AXIncrement")
        #expect(TreeRenderer.axAction(named: "Raise", in: info) == nil)
    }
}

@Suite struct MCPFramingTests {
    /// initialize, tools/list and an unknown tool over a real pipe pair.
    @Test func answersOverNewlineDelimitedJSON() async throws {
        let toServer = Pipe()
        let fromServer = Pipe()
        let connection = MCPConnection(engine: Engine(), input: toServer.fileHandleForReading,
                                       output: fromServer.fileHandleForWriting)
        let serving = Task.detached { await connection.serve() }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#,
        ]
        toServer.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try toServer.fileHandleForWriting.close()
        await serving.value
        try fromServer.fileHandleForWriting.close()
        let lines = try String(decoding: fromServer.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map { line in
                try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        #expect(lines.count == 3)
        #expect((lines[0]["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        let tools = ((lines[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(tools?.count == 10)
        #expect(tools?.contains("get_app_state") == true)
        let error = lines[2]["result"] as? [String: Any]
        #expect(error?["isError"] as? Bool == true)
    }
}
