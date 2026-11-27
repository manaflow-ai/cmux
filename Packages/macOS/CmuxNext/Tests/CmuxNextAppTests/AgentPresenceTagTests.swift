import AppKit
@testable import CmuxNextTabs
import Testing

/// The pane's agent name tag shows its whole text when it has room. A real
/// capture showed "Codex · Run…g a command" in a 1650 pt pane: the tag sized
/// its label to `intrinsicContentSize`, about 4 pt narrower than the text
/// field's cell needs, so middle truncation cut 3-4 characters.
@MainActor
struct AgentPresenceTagTests {
    @Test(arguments: ["Codex · Running a command", "Claude Code · Editing presence_tag_measurement.rs"])
    func aTagSizedForItsTextShowsAllOfIt(_ summary: String) throws {
        let tag = AgentPresenceTagView(frame: .zero)
        tag.configure(TabPresence(colorKey: "s1", summary: summary))
        tag.frame = NSRect(origin: .zero, size: tag.fittingSize(maxWidth: 1000))
        tag.layoutSubtreeIfNeeded()
        // The label's frame holds the text's whole width (a narrower frame truncates it).
        #expect(tag.label.bounds.width >= tag.label.naturalSize.width, "the label truncates")
    }
}
