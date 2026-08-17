/// App-bundle-resolved validation messages for the beta remote-default debug
/// RPCs. The coordinator package has no copy of the app's localization catalog,
/// so its context supplies these strings.
public struct ControlDebugBetaRemoteDefaultStrings: Sendable, Equatable {
    public let missingKey: String
    public let notFound: String
    public let missingValue: String
    public let invalidValue: String

    public init(
        missingKey: String,
        notFound: String,
        missingValue: String,
        invalidValue: String
    ) {
        self.missingKey = missingKey
        self.notFound = notFound
        self.missingValue = missingValue
        self.invalidValue = invalidValue
    }
}
