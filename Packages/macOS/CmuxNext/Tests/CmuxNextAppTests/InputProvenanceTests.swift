import AppKit
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// SwiftUI runs a switch's change after the click's dispatch ends, so the
/// user-only check reads the provenance of the last input event the app
/// dispatched, not only the event in dispatch.
@MainActor
struct InputProvenanceTests {
    private func click(at uptime: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: uptime, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    @Test func aPostedClickStaysSyntheticAfterItsDispatch() throws {
        let provenance = InputProvenance()
        let now: TimeInterval = 1000
        let posted = click(at: now)
        SyntheticInput.register([posted])
        provenance.note(posted)
        // The switch's change runs after sendEvent returned: still the posted click.
        #expect(provenance.lastInputIsSynthetic(now: now + 0.2))
        let descriptor = try #require(SettingsSchema.descriptor(for: MacScreenSettings.systemShortcutsPath))
        #expect(!AppServices.systemShortcutsWriter(syntheticEvent: provenance.lastInputIsSynthetic(now: now + 0.2), run: nil)
            .mayWrite(descriptor))
        // A person's click after it is the person.
        provenance.note(click(at: now + 0.5))
        #expect(!provenance.lastInputIsSynthetic(now: now + 0.6))
        // An accessibility press long after any click has no event: the person.
        provenance.note(posted)
        #expect(!provenance.lastInputIsSynthetic(now: now + 5))
    }
}
