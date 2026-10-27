import AppKit
@testable import CmuxNextTabs
import Testing

/// Chrome-parity p03-rendering-065 (MQ-damage-owners, CmuxNextTabs): a pane's agent tag follows the
/// agent's activity ("Editing app.rs:42", then "Running a command"), which changes at the agent's
/// pace while the window is otherwise idle. A new summary repaints the label only: the tag's fill
/// and ink follow the agent, and the pane frames the tag to its text. Chromium invalidates paint
/// for the properties that changed (third_party/blink/renderer/core/paint/paint_invalidator.cc).
@MainActor
struct TabsInvalidationTests {
    @Test func anAgentsNextActivityRepaintsOnlyItsText() {
        let tag = AgentPresenceTagView(frame: .zero)
        tag.configure(TabPresence(colorKey: "s1", summary: "Claude Code · Editing app.rs:42"))
        tag.frame = NSRect(origin: .zero, size: tag.fittingSize(maxWidth: 1000))
        tag.layoutSubtreeIfNeeded()
        tag.needsDisplay = false
        tag.configure(TabPresence(colorKey: "s1", summary: "Claude Code · Running a command"))
        #expect(!tag.needsDisplay, "the same agent's colors repainted")
        tag.configure(TabPresence(colorKey: "s2", summary: "Codex · Reading"))
        #expect(tag.needsDisplay, "another agent's color")
    }
}
