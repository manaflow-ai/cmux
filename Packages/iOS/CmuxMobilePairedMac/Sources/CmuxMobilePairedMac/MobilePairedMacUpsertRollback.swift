public import Foundation

/// The exact durable state that existed before an upsert lost ownership.
///
/// `previousMac` retains its original account/team scope so a selected-team
/// write that claimed a teamless legacy row can move it back during rollback.
/// The compensating timestamp is strictly newer than the rejected write so a
/// last-write-wins backup cannot later restore the rejected value.
public struct MobilePairedMacUpsertRollback: Sendable {
    /// Device whose rejected upsert must be removed or replaced.
    public let rejectedMacDeviceID: String
    /// Account scope used by the rejected upsert.
    public let rejectedStackUserID: String?
    /// Team scope used by the rejected upsert.
    public let rejectedTeamID: String?
    /// Full record before the rejected upsert, including its original scope.
    public let previousMac: MobilePairedMac?
    /// Active selection before the rejected upsert.
    public let previousActiveMac: MobilePairedMac?
    /// Version used by the local restore and remote compensation.
    public let compensatingTimestamp: Date

    /// Capture a rollback and compute a version newer than the rejected write.
    public init(
        rejectedMacDeviceID: String,
        rejectedStackUserID: String?,
        rejectedTeamID: String?,
        previousMac: MobilePairedMac?,
        previousActiveMac: MobilePairedMac?,
        rejectedTimestamp: Date,
        now: Date = Date()
    ) {
        self.rejectedMacDeviceID = rejectedMacDeviceID
        self.rejectedStackUserID = rejectedStackUserID
        self.rejectedTeamID = rejectedTeamID
        self.previousMac = previousMac
        self.previousActiveMac = previousActiveMac
        self.compensatingTimestamp = max(
            now,
            rejectedTimestamp.addingTimeInterval(0.001)
        )
    }

    /// Rebuild a rollback while preserving an already-computed compensation version.
    public init(
        rejectedMacDeviceID: String,
        rejectedStackUserID: String?,
        rejectedTeamID: String?,
        previousMac: MobilePairedMac?,
        previousActiveMac: MobilePairedMac?,
        compensatingTimestamp: Date
    ) {
        self.rejectedMacDeviceID = rejectedMacDeviceID
        self.rejectedStackUserID = rejectedStackUserID
        self.rejectedTeamID = rejectedTeamID
        self.previousMac = previousMac
        self.previousActiveMac = previousActiveMac
        self.compensatingTimestamp = compensatingTimestamp
    }
}
