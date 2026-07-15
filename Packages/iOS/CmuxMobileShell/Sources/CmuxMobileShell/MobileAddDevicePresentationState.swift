/// Tracks ownership of the shared Add Computer sheet so automatic discovery
/// cannot dismiss or replace a user-owned presentation.
public struct MobileAddDevicePresentationState: Equatable, Sendable {
    /// Current presentation owner, or `nil` when the sheet is hidden.
    public private(set) var origin: MobileAddDevicePresentationOrigin?

    /// Creates presentation state with an optional current owner.
    /// - Parameter origin: Initial presentation owner, or `nil` for a hidden sheet.
    public init(origin: MobileAddDevicePresentationOrigin? = nil) {
        self.origin = origin
    }

    /// Whether any owner currently presents the sheet.
    public var isPresented: Bool { origin != nil }

    /// Presents the sheet for an explicit owner.
    /// - Parameter origin: Owner taking responsibility for the presentation.
    public mutating func present(origin: MobileAddDevicePresentationOrigin) {
        self.origin = origin
    }

    /// Presents automatic first-connection pairing only when no other owner exists.
    public mutating func presentAutomaticallyIfUnowned() {
        guard origin == nil else { return }
        origin = .automaticFirstConnection
    }

    /// Promotes automatic presentation to user ownership after meaningful input.
    public mutating func claimAutomaticForUserInteraction() {
        guard origin == .automaticFirstConnection else { return }
        origin = .userInitiated
    }

    /// Dismisses the sheet regardless of its current owner.
    public mutating func dismiss() {
        origin = nil
    }

    /// Dismisses only a sheet owned by automatic first-connection discovery.
    public mutating func dismissAutomaticForAvailableSession() {
        guard origin == .automaticFirstConnection else { return }
        origin = nil
    }
}
