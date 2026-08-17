/// One exact stored paired-Mac row identity — the four-part owner key a
/// `removeExactScope` deletion targets — as a value, so several rows can be
/// removed in one batched call.
public struct MobilePairedMacExactScope: Sendable, Equatable {
    public let macDeviceID: String
    public let instanceTag: String?
    public let stackUserID: String?
    public let teamID: String?

    public init(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) {
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.stackUserID = stackUserID
        self.teamID = teamID
    }
}
