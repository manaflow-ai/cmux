import CmuxBrowserStream
@testable import CmuxNextMobileHostUI
import CoreGraphics
import Testing

@Suite("browser DevTools input")
struct BrowserCDPInputTests {
    @Test func aTapIsAPressAndReleaseAtTheCSSPoint() {
        let down = BrowserCDPInput.calls(for: .pointer(kind: .down, x: 10, y: 20, button: 0, buttons: 1, clickCount: 1,
                                                       modifiers: [.shift, .command], pointerType: "touch"))
        #expect(down == [CDPCall(method: "Input.dispatchMouseEvent", params: [
            "type": .string("mousePressed"), "x": .double(10), "y": .double(20), "button": .string("left"), "buttons": .int(1),
            "clickCount": .int(1), "modifiers": .int(12), "pointerType": .string("mouse"),
        ])])
        let move = BrowserCDPInput.calls(for: .pointer(kind: .move, x: 1, y: 2, button: 0, buttons: 0, clickCount: 0,
                                                       modifiers: [], pointerType: "mouse"))
        #expect(move.first?.params["type"] == .string("mouseMoved"))
        #expect(move.first?.params["button"] == .string("none"))
        #expect(move.first?.params["clickCount"] == .int(0))
    }

    @Test func keysCarryTextAndVirtualCodesAndIMECommitsInsertText() {
        let enter = BrowserCDPInput.calls(for: .key(RbKeyEvent(down: true, code: "Enter", key: "Enter", text: "\r",
                                                               unmodifiedText: "\r", modifiers: [], isRepeat: false,
                                                               location: 0, editCommands: [])))
        #expect(enter.first?.params["type"] == .string("keyDown"))
        #expect(enter.first?.params["windowsVirtualKeyCode"] == .int(13))
        let up = BrowserCDPInput.calls(for: .key(RbKeyEvent(down: false, code: "KeyA", key: "a", text: "", unmodifiedText: "",
                                                            modifiers: [.control], isRepeat: false, location: 0, editCommands: [])))
        #expect(up.first?.params["type"] == .string("keyUp"))
        #expect(up.first?.params["windowsVirtualKeyCode"] == .int(65))
        #expect(up.first?.params["modifiers"] == .int(2))
        #expect(BrowserCDPInput.calls(for: .imeCommit(text: "日本", replacement: nil))
            == [CDPCall(method: "Input.insertText", params: ["text": .string("日本")])])
        #expect(BrowserCDPInput.calls(for: .pinch(phase: .began, scale: 2, x: 0, y: 0)).isEmpty)
        let wheel = BrowserCDPInput.calls(for: .wheel(x: 5, y: 6, dx: 0, dy: -40, precise: true, phase: .changed,
                                                      momentumPhase: .none, modifiers: []))
        #expect(wheel.first?.params["deltaY"] == .double(-40))
    }

    @Test func simulatorTouchesMapBelowTheTitleBarAndClamp() {
        let geometry = SimulatorWindowGeometry(windowFrame: CGRect(x: 100, y: 50, width: 400, height: 828))
        #expect(geometry.contentRect == CGRect(x: 0, y: 28, width: 400, height: 800))
        #expect(geometry.globalPoint(x: 10, y: 20) == CGPoint(x: 110, y: 98))
        #expect(geometry.globalPoint(x: -5, y: 900) == CGPoint(x: 100, y: 878))
    }
}
