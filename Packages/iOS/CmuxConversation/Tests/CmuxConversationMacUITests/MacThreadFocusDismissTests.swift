import AppKit
import Foundation
import Testing
@testable import CmuxConversationCore
@testable import CmuxConversationMacUI

/// Reply mode's thread focus: a click on the blurred backdrop leaves it, a
/// click on a thread bubble does not. The thread rows span the whole
/// transcript width, so a click beside a bubble (in the row's band) is still a
/// click on the backdrop, as in Messages.
extension MacKeyboardSelectionTests {
    private func threadFocus(in lab: Lab) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "conversation.threadFocus" { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(lab.controller.view)
    }

    /// The thread focus's row for the replied-to message (m6, incoming).
    private func threadRow(in focus: NSView) -> MacMessageRowView? {
        func find(_ view: NSView) -> MacMessageRowView? {
            if let row = view as? MacMessageRowView, row.model?.message.id == "m6" { return row }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        // Off screen nothing runs a layout pass; place the rows as a window would.
        focus.subviews.forEach { $0.needsLayout = true }
        focus.layoutSubtreeIfNeeded()
        func layOut(_ view: NSView) { view.needsLayout = true; view.layoutSubtreeIfNeeded(); view.subviews.forEach(layOut) }
        layOut(focus)
        return find(focus)
    }

    private func labPoint(_ point: CGPoint, from view: NSView, in lab: Lab) throws -> CGPoint {
        let content = try #require(lab.window.contentView)
        let inWindow = view.convert(point, to: nil)
        return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
    }

    @Test func clickingBesideAThreadBubbleLeavesReplyMode() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("cmd+r")
        #expect(lab.controller.replyTarget?.id == "m6")
        let focus = try #require(threadFocus(in: lab))
        let row = try #require(threadRow(in: focus))
        let bubble = row.contentFrame
        // Same height as the bubble, well to its right: blurred backdrop.
        let beside = CGPoint(x: min(row.bounds.width - 20, bubble.maxX + 120), y: bubble.midY)
        #expect(row.bounds.width > bubble.maxX + 40)
        #expect(!bubble.contains(beside))
        lab.click(try labPoint(beside, from: row, in: lab), count: 1)
        #expect(lab.controller.replyTarget == nil)
        #expect(!lab.controller.composer.isReplyMode)
    }

    @Test func clickingAThreadBubbleKeepsReplyMode() async throws {
        let lab = try await Lab()
        lab.focusComposer()
        lab.key("cmd+r")
        let focus = try #require(threadFocus(in: lab))
        let row = try #require(threadRow(in: focus))
        let bubble = row.contentFrame
        lab.click(try labPoint(CGPoint(x: bubble.midX, y: bubble.midY), from: row, in: lab), count: 1)
        #expect(lab.controller.replyTarget?.id == "m6")
        #expect(lab.controller.composer.isReplyMode)
    }
}
