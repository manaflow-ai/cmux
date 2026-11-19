#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileAgentChat

/// VoiceOver on a closed "Worked for" line (cmux#45282, Leo 2026-11-17: "can we also just for the
/// gui on ios collapse the agent messages that come in by default?"). At rest the line is drawn
/// natively, so what VoiceOver reads is the cell's accessibility tree: one button that says how
/// long the turn worked, that it is collapsed, and what a double tap does, the same as the open
/// SwiftUI line's button ("Expanded").
@MainActor
@Suite struct WorkedForAccessibilityTests {
    @Test func aClosedWorkedForLineReadsAsOneCollapsedButton() throws {
        let fold = try #require(WorkedFoldTests.fold(WorkedFoldTests.rows()))
        let environment = ChatNativeEnvironment(width: 362, category: .large, wrapCode: false)
        let layout = try #require(ChatNativeLayout.make(.worked(fold), id: WorkedFold.rowID(turnID: fold.turnID), expanded: false,
                                                        environment: environment), "a closed Worked for line is drawn natively")
        let cell = ChatNativeRowCell(frame: CGRect(x: 0, y: 0, width: 402, height: layout.height))
        cell.apply(layout, actions: ChatNativeActions())
        cell.layoutIfNeeded()

        let elements = (cell.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        #expect(elements.count == 1, "the line is one element, not its words and chevron apart: \(elements)")
        let line = try #require(elements.first as? UIAccessibilityElement)
        #expect(line.accessibilityTraits.contains(.button))
        #expect(line.accessibilityLabel == "Worked for 1m 9s")
        #expect(line.accessibilityValue == "Collapsed")
        #expect(line.accessibilityHint == "Shows details")
        #expect(line.accessibilityIdentifier == "agent-chat.worked-for")
    }
}
#endif
