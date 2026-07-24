import AppKit
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator remote surface focus")
@MainActor
struct SimulatorRemoteSurfaceFocusTests {
    @Test("Scroll input follows host pointer ownership")
    func scrollRequiresPointerOwnership() throws {
        let view = SimulatorRemoteSurfaceView()
        var guestInvocationCount = 0
        view.onMessage = { _ in guestInvocationCount += 1 }
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 12,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))

        view.scrollWheel(with: event)
        #expect(guestInvocationCount == 0)

        view.setPointerInputEnabled(true)
        view.scrollWheel(with: event)
        #expect(guestInvocationCount > 0)
    }

    @Test("Host Command shortcuts run before guest key forwarding")
    func hostCommandShortcutWins() throws {
        let view = SimulatorRemoteSurfaceView()
        var hostInvocationCount = 0
        var guestInvocationCount = 0
        view.hostKeyEquivalentHandler = { _ in
            hostInvocationCount += 1
            return true
        }
        view.onMessage = { _ in guestInvocationCount += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ))

        #expect(view.performKeyEquivalent(with: event))
        #expect(hostInvocationCount == 1)
        #expect(guestInvocationCount == 0)
    }

    @Test("A pre-window focus request is fulfilled after window attachment")
    func pendingFocusSurvivesWindowAttachment() {
        let view = SimulatorRemoteSurfaceView()
        view.requestFocus(generation: 1)

        #expect(view.window == nil)
        #expect(view.pendingFocusGeneration == 1)
        #expect(view.handledFocusGeneration == 0)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        #expect(window.firstResponder === view)
        #expect(view.pendingFocusGeneration == nil)
        #expect(view.handledFocusGeneration == 1)
    }
}
