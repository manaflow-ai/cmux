import AppKit
import Testing
@testable import MessagesLabHome

/// VoiceOver draws its cursor at the frame the focused element had when it last heard of it. AppKit posts no notice
/// when a view's frame changes, so after the Home pane got narrower (a browser opened beside the docked Chief) or
/// zoomed and unzoomed, VoiceOver's cursor stayed at the compose field's old, wider frame, over the browser beside the
/// chat (fleet capture, Nov 24). The field tells assistive apps each time it moves or changes size, once, and says
/// nothing when its frame is unchanged.
@MainActor @Suite struct ComposeAccessibilityFrameTests {
    private final class Heard {
        var notices: [(NSView, NSAccessibility.Notification)] = []
    }

    private func field() -> (ComposeTextView, Heard) {
        let heard = Heard()
        let field = ComposeTextView { heard.notices.append(($0, $1)) }
        field.place(CGRect(x: 10, y: 10, width: 700, height: 36))
        heard.notices = []
        return (field, heard)
    }

    @Test func aNarrowerFieldTellsAssistiveAppsItChangedSize() {
        let (field, heard) = field()
        field.place(CGRect(x: 10, y: 10, width: 360, height: 36))
        #expect(heard.notices.contains { $0.0 === field.view && $0.1 == .resized }, "VoiceOver hears no new size: \(heard.notices.map(\.1))")
        #expect(heard.notices.filter { $0.1 == .resized }.count == 1, "the size notice comes more than once: \(heard.notices.map(\.1))")
    }

    @Test func aMovedFieldTellsAssistiveAppsItMoved() {
        let (field, heard) = field()
        field.place(CGRect(x: 10, y: 80, width: 700, height: 36))
        #expect(heard.notices.contains { $0.0 === field.view && $0.1 == .moved }, "VoiceOver hears no move: \(heard.notices.map(\.1))")
        #expect(!heard.notices.contains { $0.1 == .resized }, "a move alone tells of a new size")
    }

    @Test func anUnchangedFrameSaysNothing() {
        let (field, heard) = field()
        field.place(CGRect(x: 10, y: 10, width: 700, height: 36))
        #expect(heard.notices.isEmpty, "the same frame posts \(heard.notices.map(\.1))")
    }
}
