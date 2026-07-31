#if DEBUG
/// A DEBUG readback of one Beta Features remote-default resolution.
public struct ControlDebugBetaRemoteDefaultSnapshot: Sendable, Equatable {
    public let settingID: String
    public let flagKey: String
    public let userKeyPresent: Bool
    public let userValue: Bool?
    public let remoteDefault: Bool?
    public let effectiveValue: Bool
    public let source: String

    public init(
        settingID: String,
        flagKey: String,
        userKeyPresent: Bool,
        userValue: Bool?,
        remoteDefault: Bool?,
        effectiveValue: Bool,
        source: String
    ) {
        self.settingID = settingID
        self.flagKey = flagKey
        self.userKeyPresent = userKeyPresent
        self.userValue = userValue
        self.remoteDefault = remoteDefault
        self.effectiveValue = effectiveValue
        self.source = source
    }
}
#endif
