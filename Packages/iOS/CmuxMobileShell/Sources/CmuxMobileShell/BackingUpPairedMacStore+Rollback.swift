public import CmuxMobilePairedMac

extension BackingUpPairedMacStore {
    /// Restore local state first, then publish one newer compensating backup
    /// batch in the rejected write's captured account/team scope.
    public func rollbackRejectedUpsert(
        _ rollback: MobilePairedMacUpsertRollback
    ) async throws {
        try await inner.rollbackRejectedUpsert(rollback)
        guard let account = rollback.rejectedStackUserID, !account.isEmpty else { return }
        lastSignedInAccount = account

        var ops: [PairedMacBackupOp] = []
        if var previousMac = rollback.previousMac {
            previousMac.lastSeenAt = rollback.compensatingTimestamp
            ops.append(.upsert(
                Self.backupRecord(from: previousMac),
                instanceAuthority: .authoritative
            ))
        } else {
            ops.append(.delete(macDeviceID: rollback.rejectedMacDeviceID))
        }
        if var previousActiveMac = rollback.previousActiveMac,
           previousActiveMac.macDeviceID != rollback.previousMac?.macDeviceID
            || previousActiveMac.stackUserID != rollback.previousMac?.stackUserID
            || previousActiveMac.teamID != rollback.previousMac?.teamID {
            previousActiveMac.isActive = true
            previousActiveMac.lastSeenAt = rollback.compensatingTimestamp
            ops.append(.upsert(
                Self.backupRecord(from: previousActiveMac),
                instanceAuthority: .preserve
            ))
        }
        _ = await backup.upload(
            ops: ops,
            teamID: rollback.rejectedTeamID,
            expectedUserID: account
        )
    }
}
