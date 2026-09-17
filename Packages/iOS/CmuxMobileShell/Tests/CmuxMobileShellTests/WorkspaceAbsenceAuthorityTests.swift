import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@Suite struct WorkspaceAbsenceAuthorityTests {
    @Test func foregroundRowAbsenceIsAuthoritativeOnlyWhileHealthy() {
        // Deleted while the foreground connection is live: retarget/pop.
        #expect(WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: true,
            foregroundIsHealthy: true,
            ownerStatus: .connected
        ))
        // Vanished mid-recovery: a transient hole, hold the selection.
        #expect(!WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: true,
            foregroundIsHealthy: false,
            ownerStatus: .connected
        ))
    }

    @Test func secondaryRowAbsenceFollowsItsOwnEntryStatus() {
        // A secondary Mac's live list omitted the workspace: deletion.
        #expect(WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: false,
            foregroundIsHealthy: false,
            ownerStatus: .connected
        ))
        // The secondary went offline or is redialing: hold the selection.
        #expect(!WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: false,
            foregroundIsHealthy: true,
            ownerStatus: .unavailable
        ))
        #expect(!WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: false,
            foregroundIsHealthy: true,
            ownerStatus: .reconnecting
        ))
    }

    @Test func missingOwnerEntryIsAuthoritativeOnlyWhileForegroundIsHealthy() {
        // Unpair/hide removes the entry while the shell is healthy: pop.
        #expect(WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: false,
            foregroundIsHealthy: true,
            ownerStatus: nil
        ))
        // Foreground death purges secondary snapshots: hold the selection.
        #expect(!WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: true,
            rowIsForegroundServed: false,
            foregroundIsHealthy: false,
            ownerStatus: nil
        ))
    }

    @Test func unknownRowFallsBackToForegroundHealth() {
        #expect(WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: false,
            rowIsForegroundServed: false,
            foregroundIsHealthy: true,
            ownerStatus: nil
        ))
        #expect(!WorkspaceAbsenceAuthority.absenceIsAuthoritative(
            hasLastKnownRow: false,
            rowIsForegroundServed: false,
            foregroundIsHealthy: false,
            ownerStatus: nil
        ))
    }
}
