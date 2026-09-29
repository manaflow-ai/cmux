import Testing
@testable import CmuxTerminalCore

/// #8810 426ms-delay investigation: `isTransitionSnapshot` (flags bit 1)
/// must decode independently of `firstForActivation` (flags bit 0) — a
/// decoder needs to tell a transition-snapshot marker apart from an
/// ordinary render-verdict entry for the SAME activation without relying
/// on push order/seq alone. `describeLine` must surface the new field so
/// a human grepping the log can see it directly rather than needing to
/// re-decode the raw `flags` byte themselves.
@Suite struct ExternalHoverDiagEntryValueTests {
    @Test func isTransitionSnapshotDecodesIndependentlyOfFirstForActivation() {
        let neither = ExternalHoverDiagEntryValue(event: 1, source: 3, reason: 0, verdict: 1, flags: 0, seq: 0)
        #expect(!neither.firstForActivation)
        #expect(!neither.isTransitionSnapshot)

        let firstOnly = ExternalHoverDiagEntryValue(event: 1, source: 3, reason: 0, verdict: 1, flags: 0x1, seq: 1)
        #expect(firstOnly.firstForActivation)
        #expect(!firstOnly.isTransitionSnapshot)

        let snapshotOnly = ExternalHoverDiagEntryValue(event: 1, source: 3, reason: 0, verdict: 0, flags: 0x2, seq: 2)
        #expect(!snapshotOnly.firstForActivation)
        #expect(snapshotOnly.isTransitionSnapshot)

        let both = ExternalHoverDiagEntryValue(event: 1, source: 3, reason: 0, verdict: 1, flags: 0x3, seq: 3)
        #expect(both.firstForActivation)
        #expect(both.isTransitionSnapshot)
    }

    @Test func describeLineSurfacesTheTransitionSnapshotField() {
        let entry = ExternalHoverDiagEntryValue(event: 7, source: 3, reason: 0, verdict: 0, flags: 0x2, seq: 5)
        let line = entry.describeLine(surfaceSerial: 99)
        #expect(line.contains("transitionSnapshot=true"))
        #expect(line.contains("firstForActivation=false"))
        #expect(line.contains("surfaceSerial=99 event=7"))
    }
}
