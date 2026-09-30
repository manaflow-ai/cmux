import AppKit
import Testing

@testable import CmuxCommandPalette
import CmuxFoundation

/// A focus-stealing surface stand-in (mirrors how `GhosttyNSView` /
/// `GhosttySurfaceScrollView` conform to the marker in the app target).
private final class FocusStealingSurfaceView: NSView, FocusStealingResponder {}

/// A view that is not a focus stealer (mirrors ordinary chrome / overlay views).
private final class UnrelatedView: NSView {}

/// A non-view text delegate (SwiftUI can attach one to field editors).
private final class NonViewTextDelegate: NSObject, NSTextViewDelegate {}

@MainActor
@Suite struct CommandPaletteFocusStealingTests {
    @Test func treatsSurfaceViewAsFocusStealer() {
        let surfaceView = FocusStealingSurfaceView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        #expect(surfaceView.commandPaletteFocusStealingSurfaceInViewHierarchy)
        #expect((surfaceView as NSResponder).isCommandPaletteFocusStealingTerminalOrBrowser)
    }

    @Test func treatsTextFieldInsideSurfaceAsFocusStealer() {
        let hostedView = FocusStealingSurfaceView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        hostedView.addSubview(textField)

        #expect(
            (textField as NSResponder).isCommandPaletteFocusStealingTerminalOrBrowser,
            "Terminal-owned overlay text inputs should not be allowed to reclaim focus from the command palette"
        )
    }

    @Test func doesNotTreatUnrelatedTextFieldAsFocusStealer() {
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        #expect(!(textField as NSResponder).isCommandPaletteFocusStealingTerminalOrBrowser)
    }

    @Test func doesNotReadTextViewDelegateForClassification() {
        final class DelegateTrackingTextView: NSTextView {
            private(set) var delegateReadCount = 0
            override var delegate: (any NSTextViewDelegate)? {
                get {
                    delegateReadCount += 1
                    return super.delegate
                }
                set { super.delegate = newValue }
            }
        }

        let textView = DelegateTrackingTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        #expect(!(textView as NSResponder).isCommandPaletteFocusStealingTerminalOrBrowser)
        #expect(
            textView.delegateReadCount == 0,
            "Command palette focus-stealer classification must avoid NSTextView.delegate because AppKit exposes it as unsafe-unretained"
        )
    }

    @Test func treatsTextViewInsideSurfaceAsFocusStealerWhenDelegateIsNotAView() {
        let hostedView = FocusStealingSurfaceView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        let delegate = NonViewTextDelegate()
        textView.delegate = delegate
        hostedView.addSubview(textView)

        #expect(
            (textView as NSResponder).isCommandPaletteFocusStealingTerminalOrBrowser,
            "NSTextView responders should still be blocked via the NSView hierarchy walk when the delegate is not a view"
        )
    }

    @Test func unrelatedHostedViewIsNotFocusStealer() {
        let hostedView = UnrelatedView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        hostedView.addSubview(textField)
        #expect(!(textField as NSResponder).isCommandPaletteFocusStealingTerminalOrBrowser)
    }
}
