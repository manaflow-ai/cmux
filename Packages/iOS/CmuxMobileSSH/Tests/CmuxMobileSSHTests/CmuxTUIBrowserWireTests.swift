@testable import CmuxMobileSSH
import Foundation
import Testing

/// Lab-free decoding of cmux-tui browser wire shapes. Samples follow the
/// server serializers (`crates/cmux-tui-core/src/server.rs`:
/// `pane_json`, `BrowserStateMessage`, `browser_frame_json`) and
/// cmux-tui/spec/events.md.
@Suite struct CmuxTUIBrowserWireTests {
    static let listWorkspaces = #"""
    {"id":"r3","ok":true,"data":{"workspace_revision":4,"workspaces":[{"id":4,"key":"6ba7b810-9dad-41d1-80b4-00c04fd430c8","resource_id":"ws_1","name":"api","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"layout":{"type":"leaf","pane":2},"panes":[{"id":2,"name":null,"active_tab":1,"focused_at":1,"tabs":[{"surface":1,"tab_resource_id":"tab_a","content_resource_id":"term_a","terminal_id":"t-1","terminal_resource_id":"term_a","kind":"pty","browser_source":null,"browser_status":null,"browser_error":null,"browser_frames_stalled":null,"url":null,"name":null,"title":"zsh","size":{"cols":80,"rows":24},"dead":false},{"surface":7,"tab_resource_id":"tab_b","content_resource_id":"brw_0001","terminal_id":null,"terminal_resource_id":null,"kind":"browser","browser_source":"external","browser_status":"live","browser_error":null,"browser_frames_stalled":false,"url":"https://example.com/","name":null,"title":"Example Domain","size":{"cols":120,"rows":40},"dead":false}]}]}]}]}}
    """#

    static let initialState = #"""
    {"event":"browser-state","surface":7,"cols":120,"rows":40,"url":"https://example.com/","title":"Example Domain","status":"live","error":null,"pointer_frame_floor_seq":8,"pointer_frame_seq":9,"frames_stalled":false,"frame":{"seq":42,"width":1080,"height":640,"image_width":2160,"image_height":1280,"data":"Zmlyc3Q="}}
    """#

    static let frameEvent = #"""
    {"event":"frame","surface":7,"seq":43,"width":1080,"height":640,"image_width":1080,"image_height":640,"data":"c2Vjb25k","status":"live","error":null,"pointer_frame_floor_seq":8,"pointer_frame_seq":10}
    """#

    static let navigatingState = #"""
    {"event":"browser-state","surface":7,"cols":120,"rows":40,"url":"https://next.test/","title":"","status":"starting","error":null,"pointer_frame_floor_seq":null,"pointer_frame_seq":null,"frames_stalled":false}
    """#

    static let failedState = #"""
    {"event":"browser-state","surface":7,"cols":120,"rows":40,"url":"about:blank","title":"","status":"failed","error":"browser is not responding","pointer_frame_floor_seq":null,"pointer_frame_seq":null,"frames_stalled":true}
    """#

    @Test func listWorkspacesSeparatesBrowserTabs() throws {
        let response = try CmuxTUIRawResponse<CmuxTUITreeWire>(cmuxTUILine: Data(Self.listWorkspaces.utf8))
        let workspace = try #require(response.data?.model.first)
        #expect(workspace.terminals.map(\.surface) == [1])
        #expect(workspace.browsers.count == 1)
        let browser = try #require(workspace.browsers.first)
        #expect(browser.surface == 7)
        #expect(browser.pane == 2)
        #expect(browser.screen == 3)
        #expect(browser.resourceID == "brw_0001")
        #expect(browser.url == "https://example.com/")
        #expect(browser.title == "Example Domain")
        #expect(browser.status == .live)
        #expect(browser.cols == 120 && browser.rows == 40)
        #expect(!browser.dead && !browser.framesStalled)
    }

    @Test func initialStateCarriesFrameAndPointerRange() throws {
        let decoded = try #require(CmuxTUIBrowserEventWire(line: Data(Self.initialState.utf8))?.surfaceEvent)
        #expect(decoded.surface == 7)
        guard case .state(let state) = decoded.event else { Issue.record("expected state"); return }
        #expect(state.url == "https://example.com/")
        #expect(state.title == "Example Domain")
        #expect(state.status == .live)
        #expect(state.cols == 120 && state.rows == 40)
        #expect(state.pointerFrameFloorSeq == 8 && state.pointerFrameSeq == 9)
        let frame = try #require(state.frame)
        #expect(frame.seq == 42)
        #expect(frame.width == 1080 && frame.height == 640)
        #expect(frame.imageWidth == 2160 && frame.imageHeight == 1280)
        #expect(frame.png == Data("first".utf8))
        #expect(frame.pointerFrameSeq == 9)
    }

    @Test func frameEventCouplesPixelsWithAuthority() throws {
        let decoded = try #require(CmuxTUIBrowserEventWire(line: Data(Self.frameEvent.utf8))?.surfaceEvent)
        guard case .frame(let frame) = decoded.event else { Issue.record("expected frame"); return }
        #expect(frame.seq == 43)
        #expect(frame.status == .live)
        #expect(frame.pointerFrameFloorSeq == 8 && frame.pointerFrameSeq == 10)
        #expect(frame.base64PNG == "c2Vjb25k")
    }

    @Test func frameWithoutImageSizeFallsBackToCSSSize() throws {
        let line = #"{"event":"frame","surface":7,"seq":1,"width":300,"height":200,"data":"AA==","status":"live","pointer_frame_seq":1}"#
        let decoded = try #require(CmuxTUIBrowserEventWire(line: Data(line.utf8))?.surfaceEvent)
        guard case .frame(let frame) = decoded.event else { Issue.record("expected frame"); return }
        #expect(frame.imageWidth == 300 && frame.imageHeight == 200)
        #expect(frame.pointerFrameFloorSeq == nil && frame.pointerFrameSeq == 1)
    }

    @Test func failedAndStartingStatesDecode() throws {
        let failed = try #require(CmuxTUIBrowserEventWire(line: Data(Self.failedState.utf8))?.surfaceEvent)
        guard case .state(let state) = failed.event else { Issue.record("expected state"); return }
        #expect(state.status == .failed)
        #expect(state.error == "browser is not responding")
        #expect(state.framesStalled)
        #expect(state.frame == nil)

        let starting = try #require(CmuxTUIBrowserEventWire(line: Data(Self.navigatingState.utf8))?.surfaceEvent)
        guard case .state(let navigating) = starting.event else { Issue.record("expected state"); return }
        #expect(navigating.status == .starting)
        #expect(navigating.pointerFrameSeq == nil)
    }

    @Test func nonBrowserEventsAreIgnored() {
        #expect(CmuxTUIBrowserEventWire(line: Data(#"{"event":"output","surface":1,"data":"aGk="}"#.utf8))?.surfaceEvent == nil)
        #expect(CmuxTUIBrowserEventWire(line: Data(#"{"event":"frame","surface":1}"#.utf8))?.surfaceEvent == nil)
    }

    // Mirrors `browser_state_cannot_grant_new_authority_to_cached_pixels` and
    // the pointer-range tests in crates/cmux-tui/src/session/remote.rs.
    @Test func pointerGuardRequiresPresentedTokenInRange() throws {
        var guardState = CmuxTUIBrowserPointerGuard()
        guard case .state(let initial) = try #require(CmuxTUIBrowserEventWire(line: Data(Self.initialState.utf8))?.surfaceEvent).event,
              case .frame(let frame) = try #require(CmuxTUIBrowserEventWire(line: Data(Self.frameEvent.utf8))?.surfaceEvent).event,
              case .state(let navigating) = try #require(CmuxTUIBrowserEventWire(line: Data(Self.navigatingState.utf8))?.surfaceEvent).event
        else { Issue.record("decode"); return }

        guardState.apply(initial)
        #expect(guardState.pointerToken == nil, "nothing presented yet")
        #expect(!ack(&guardState, 7), "below the floor")
        #expect(ack(&guardState, 9))
        #expect(guardState.pointerToken == 9)
        #expect(!ack(&guardState, 9), "already presented")
        #expect(!ack(&guardState, 8), "older than presented")

        guardState.apply(frame)
        #expect(guardState.pointerToken == 9, "still inside 8...10")
        #expect(ack(&guardState, 10))
        #expect(guardState.pointerToken == 10)

        guardState.apply(navigating)
        #expect(guardState.pointerToken == nil, "navigation revokes authority")
        #expect(!ack(&guardState, 10))
    }

    @Test func stateAloneCannotGrantNewAuthority() {
        var guardState = CmuxTUIBrowserPointerGuard()
        let stateOnly = CmuxTUIBrowserState(
            cols: 80, rows: 24, url: "https://next.test", title: "next", status: .live,
            error: nil, framesStalled: false, pointerFrameFloorSeq: nil, pointerFrameSeq: 9, frame: nil
        )
        guardState.apply(stateOnly)
        #expect(!ack(&guardState, 9), "state-only authority must fail closed")

        let frame = CmuxTUIBrowserFrame(
            seq: 9, width: 80, height: 40, imageWidth: 80, imageHeight: 40, base64PNG: "Zmlyc3Q=",
            status: .live, error: nil, pointerFrameFloorSeq: nil, pointerFrameSeq: 9
        )
        guardState.apply(frame)
        #expect(ack(&guardState, 9))
        // A matching state keeps authority; a null range revokes it.
        guardState.apply(stateOnly)
        #expect(guardState.pointerToken == 9)
        var revoked = stateOnly
        revoked.pointerFrameSeq = nil
        guardState.apply(revoked)
        #expect(guardState.pointerToken == nil)
        guardState.apply(stateOnly)
        #expect(guardState.pointerToken == nil, "restoring requires a paired frame")
    }

    @Test func frameWithoutLiveStatusFailsClosed() {
        var guardState = CmuxTUIBrowserPointerGuard()
        let frame = CmuxTUIBrowserFrame(
            seq: 1, width: 10, height: 10, imageWidth: 10, imageHeight: 10, base64PNG: "",
            status: nil, error: nil, pointerFrameFloorSeq: 1, pointerFrameSeq: 1
        )
        guardState.apply(frame)
        #expect(!ack(&guardState, 1))
    }

    private func ack(_ guardState: inout CmuxTUIBrowserPointerGuard, _ token: UInt64) -> Bool {
        guardState.acknowledge(token)
    }

    @Test func keyTokensMapToCDP() throws {
        let enter = try #require(CmuxTUIBrowserKey.named("return"))
        #expect(enter.key == "Enter" && enter.windowsVirtualKeyCode == 13 && enter.text == "\r")
        let backspace = try #require(CmuxTUIBrowserKey.named("delete"))
        #expect(backspace.key == "Backspace" && backspace.windowsVirtualKeyCode == 8)
        let shiftTab = try #require(CmuxTUIBrowserKey.named("tab", modifiers: ["shift"]))
        #expect(shiftTab.modifiers == 8)
        let commandReturn = try #require(CmuxTUIBrowserKey.named("return", modifiers: ["command"]))
        #expect(commandReturn.modifiers == 4 && commandReturn.text == nil)
        #expect(CmuxTUIBrowserKey.named("up")?.code == "ArrowUp")
        #expect(CmuxTUIBrowserKey.named("nonsense") == nil)
    }

    @Test func guardedMouseRequestEncodesNumbers() throws {
        let request: [String: CmuxTUIWireValue] = [
            "cmd": .string("browser-mouse-guarded"),
            "surface": .int(7),
            "kind": .string("down"),
            "x_px": .double(12.5),
            "y_px": .double(40),
            "frame_seq": .uint(10),
        ]
        let line = try request.cmuxTUILine()
        let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(object["cmd"] as? String == "browser-mouse-guarded")
        #expect(object["x_px"] as? Double == 12.5)
        #expect(object["frame_seq"] as? Int == 10)
        #expect(line.last == 0x0A)
    }
}
