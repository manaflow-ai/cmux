import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@MainActor
@Suite struct MiddleClickCaptureViewTests {
    /// A non-middle `otherMouseDown` must fall through to `super` and never fire the handler.
    @Test func forwardButtonDownDoesNotInvokeMiddleClickHandler() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }

        // A synthesized .otherMouseDown defaults to buttonNumber 0 (not 2), so the
        // middle-click branch must be skipped.
        let event = NSEvent.mouseEvent(
            with: .otherMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        if let event {
            view.otherMouseDown(with: event)
        }
        #expect(invoked == 0)
    }

    @Test func middleButtonDownInvokesHandlerOnThePressedView() {
        let view = MiddleClickCaptureView()
        var invoked = 0
        view.onMiddleClick = { invoked += 1 }

        let source = CGEventSource(stateID: .hidSystemState)
        let event = source.flatMap {
            CGEvent(
                mouseEventSource: $0,
                mouseType: .otherMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: .center
            )
        }.flatMap(NSEvent.init(cgEvent:))
        if let event {
            view.otherMouseDown(with: event)
        }
        #expect(invoked == 1)
    }
}
