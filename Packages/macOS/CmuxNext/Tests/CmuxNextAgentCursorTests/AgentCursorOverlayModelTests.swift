import CmuxAgentCursor
import CoreGraphics
import Testing
@testable import CmuxNextAgentCursor

private func input(
    _ session: String = "s1", target: String = "tab_1", seq: UInt64 = 0, kind: AutomationInputEvent.Kind = .click,
    point: AutomationInputEvent.Point? = .init(x: 40, y: 12), rect: AutomationInputEvent.Rect? = nil, zoom: Double? = nil
) -> AutomationInputEvent {
    AutomationInputEvent(sessionID: session, targetID: target, seq: seq, kind: kind, space: .viewport,
                         point: point, rect: rect, zoom: zoom, tMs: Double(seq))
}

