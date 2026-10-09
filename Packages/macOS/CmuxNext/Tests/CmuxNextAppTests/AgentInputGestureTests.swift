@testable import CmuxNextApp
import CmuxNextBrowserAutomation
import Foundation
import Testing

/// An agent's click, key or typing in a tab (the host's `automation.input`
/// events) is a user gesture for that tab's automatic-downloads limit, as a
/// person's is. A pointer move or a scroll is not. Before, only AppKit input
/// counted, so a page's second download after an agent's click waited for a
/// question nobody could see (edge.download-concurrent on cef).
struct AgentInputGestureTests {
    private func event(_ kind: String, target: String = "tab_1") -> DriverJSON {
        .object(["v": .number(1), "session_id": .string("s"), "target_id": .string(target), "seq": .number(1),
                 "kind": .string(kind), "space": .string("css"), "t_ms": .number(0)])
    }

    @Test func clicksKeysAndTypingAreGestures() {
        for kind in ["click", "double_click", "right_click", "key", "type"] {
            #expect(AppBrowserHost.gestureTarget(of: event(kind)) == "tab_1", "\(kind)")
        }
    }

    @Test func movesScrollsAndDragsAreNot() {
        for kind in ["move", "scroll", "drag"] {
            #expect(AppBrowserHost.gestureTarget(of: event(kind)) == nil, "\(kind)")
        }
        #expect(AppBrowserHost.gestureTarget(of: .object(["kind": .string("click")])) == nil, "no target")
    }
}
