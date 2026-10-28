import AppKit
import CmuxNextInput
import CmuxNextSignposts
import Testing

/// What `CmuxApplication.sendEvent` stamps for `input.frame`: the person's key presses,
/// presses, releases, drags and scrolls, never moves, modifier changes or the app's synthetic input; and which text
/// commands count as a paste.
@MainActor @Suite struct InputFrameKindTests {
    @Test func pointerEventsMapToTheirKind() {
        let expected: [(NSEvent.EventType, InputFrameSignpost.Kind)] = [
            (.keyDown, .key), (.leftMouseDown, .mouseDown), (.rightMouseDown, .mouseDown), (.otherMouseDown, .mouseDown),
            (.leftMouseUp, .mouseUp), (.rightMouseUp, .mouseUp), (.otherMouseUp, .mouseUp),
            (.leftMouseDragged, .drag), (.rightMouseDragged, .drag), (.otherMouseDragged, .drag), (.scrollWheel, .scroll),
        ]
        for (type, kind) in expected {
            #expect(InputFrameSignpost.Kind(type, synthetic: false) == kind, "\(type.rawValue)")
        }
    }

    @Test func movesModifiersAndSyntheticInputAreNotStamped() {
        for type: NSEvent.EventType in [.mouseMoved, .flagsChanged, .keyUp, .appKitDefined, .applicationDefined] {
            #expect(InputFrameSignpost.Kind(type, synthetic: false) == nil, "\(type.rawValue)")
        }
        for type: NSEvent.EventType in [.keyDown, .leftMouseDown, .leftMouseDragged, .scrollWheel] {
            #expect(InputFrameSignpost.Kind(type, synthetic: true) == nil, "\(type.rawValue)")
        }
    }

    @Test func pasteCommandsArePastes() {
        #expect(InputFrameSignpost.Kind.pastes(#selector(NSText.paste(_:))))
        #expect(InputFrameSignpost.Kind.pastes(#selector(NSTextView.pasteAsPlainText(_:))))
        #expect(InputFrameSignpost.Kind.pastes(#selector(NSTextView.pasteAsRichText(_:))))
        #expect(!InputFrameSignpost.Kind.pastes(#selector(NSText.copy(_:))))
        #expect(!InputFrameSignpost.Kind.pastes(#selector(NSText.selectAll(_:))))
    }

    @Test func noWindowAndNoScrollLeaveNoContent() {
        #expect(!InputLatencyDispatch.leftContent(in: nil, layoutTookScroll: false))
        #expect(InputLatencyDispatch.leftContent(in: nil, layoutTookScroll: true))
    }
}
