import AppKit
import SwiftUI
import Testing
@testable import CmuxUpdaterUI

@MainActor
@Suite("Update primary button style", .serialized)
struct UpdatePrimaryButtonStyleTests {
    @Test("Primary update actions draw as key while the popover window is inactive (#18687)")
    func primaryButtonIgnoresInactiveWindowState() {
        let recorder = ControlActiveStateRecorder()
        let window = host(
            ControlActiveStateProbe(recorder: recorder)
                .updatePrimaryButtonStyle()
                .environment(\.controlActiveState, .inactive)
        )
        defer { window.orderOut(nil) }
        pump { !recorder.states.isEmpty }

        #expect(!recorder.states.isEmpty, "the probe must render")
        #expect(recorder.states.allSatisfy { $0 == .key })
    }

    @Test("The probe sees the inactive state without the primary style")
    func probeObservesInactiveStateWithoutPrimaryStyle() {
        let recorder = ControlActiveStateRecorder()
        let window = host(
            ControlActiveStateProbe(recorder: recorder)
                .environment(\.controlActiveState, .inactive)
        )
        defer { window.orderOut(nil) }
        pump { !recorder.states.isEmpty }

        #expect(recorder.states.last == .inactive)
    }

    private func host(_ view: some View) -> NSWindow {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 40)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 120, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    /// Pumps the main run loop until `condition` or a bounded deadline (test scaffolding only).
    private func pump(until condition: () -> Bool) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@MainActor
private final class ControlActiveStateRecorder {
    var states: [ControlActiveState] = []
}

private struct ControlActiveStateProbe: View {
    let recorder: ControlActiveStateRecorder
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        recorder.states.append(controlActiveState)
        return Color.clear.frame(width: 10, height: 10)
    }
}
