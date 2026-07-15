/// Connection choices available to a signed-in installation before its first attach.
public struct MobileFirstConnectionState: Equatable, Sendable {
    public let hasSavedComputer: Bool
    public let hasAccountSession: Bool

    public init(hasSavedComputer: Bool, hasAccountSession: Bool) {
        self.hasSavedComputer = hasSavedComputer
        self.hasAccountSession = hasAccountSession
    }

    public var shouldPresentManualPairing: Bool {
        !hasSavedComputer && !hasAccountSession
    }
}
