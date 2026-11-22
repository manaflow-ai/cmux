import CmuxAgentCursor
import QuartzCore
import Testing
@testable import CmuxNextAgentCursor

private func click(_ seq: UInt64, target: String) -> AutomationInputEvent {
    AutomationInputEvent(sessionID: "s1", targetID: target, seq: seq, kind: .click, space: .viewport,
                         point: .init(x: 20, y: 30), tMs: Double(seq))
}

