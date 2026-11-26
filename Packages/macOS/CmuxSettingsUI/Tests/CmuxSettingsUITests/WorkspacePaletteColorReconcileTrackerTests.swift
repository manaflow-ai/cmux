import Testing

@testable import CmuxSettingsUI

@MainActor
@Suite
struct WorkspacePaletteColorReconcileTrackerTests {
    @Test func pickerWriteAdvancesOnlyEditedEntryRevision() {
        var tracker = WorkspacePaletteColorReconcileTracker()
        tracker.startTracking([
            "Red": "#C0392B",
            "Blue": "#1565C0",
        ])

        tracker.recordPickerWrite(
            name: "Red",
            resultingHexes: [
                "Red": "#000000",
                "Blue": "#1565C0",
            ]
        )

        #expect(tracker.revision(for: "Red") == 1)
        #expect(tracker.revision(for: "Blue") == 0)

        tracker.recordPickerWrite(
            name: "Blue",
            resultingHexes: [
                "Red": "#000000",
                "Blue": "#111111",
            ]
        )

        #expect(tracker.revision(for: "Red") == 1)
        #expect(tracker.revision(for: "Blue") == 1)
    }

    @Test func externalPaletteChangeAdvancesOnlyChangedEntries() {
        var tracker = WorkspacePaletteColorReconcileTracker()
        tracker.startTracking([
            "Red": "#C0392B",
            "Blue": "#1565C0",
        ])

        tracker.reconcileExternalHexes([
            "Red": "#C0392B",
            "Blue": "#000000",
        ])

        #expect(tracker.revision(for: "Red") == 0)
        #expect(tracker.revision(for: "Blue") == 1)
    }

    @Test func paletteResetAdvancesTrackedAndResultingEntries() {
        var tracker = WorkspacePaletteColorReconcileTracker()
        tracker.startTracking([
            "Red": "#000000",
            "Custom 1": "#222222",
        ])

        tracker.recordPaletteReset(resultingHexes: [
            "Red": "#C0392B",
            "Blue": "#1565C0",
        ])

        #expect(tracker.revision(for: "Red") == 1)
        #expect(tracker.revision(for: "Blue") == 1)
        #expect(tracker.revision(for: "Custom 1") == 1)
    }
}
