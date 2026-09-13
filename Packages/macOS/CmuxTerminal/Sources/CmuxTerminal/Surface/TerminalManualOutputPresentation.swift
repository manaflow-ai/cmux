/// Tracks one remote replay until its exact output boundary is presented.
/// Reconnect replaces the receipt, so an earlier replay cannot complete it.
public struct TerminalManualOutputPresentation {
    private let expectedRevision: UInt64?
    private var presentedRevision: UInt64?

    public init(expectedRevision: UInt64? = nil) {
        self.expectedRevision = expectedRevision
    }

    public var hasReplay: Bool { expectedRevision != nil }
    public var isPresented: Bool { hasReplay && expectedRevision == presentedRevision }

    @discardableResult
    public mutating func acknowledge(_ revision: UInt64) -> Bool {
        guard revision == expectedRevision else { return false }
        presentedRevision = revision
        return true
    }
}
