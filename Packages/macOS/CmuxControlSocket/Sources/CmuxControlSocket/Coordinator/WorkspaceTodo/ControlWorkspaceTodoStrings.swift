/// App-bundle-resolved messages used by workspace-todo control commands.
///
/// The app resolves these strings because the control-socket package bundle
/// does not contain the application's localization catalog.
public struct ControlWorkspaceTodoStrings: Sendable, Equatable {
    /// The error returned when `owner_id` is absent or not a string.
    public let missingOwnerID: String

    /// The error returned when `owner_id` is empty or exceeds its length cap.
    public let invalidOwnerIDLength: String

    /// Creates the localized workspace-todo messages.
    ///
    /// - Parameters:
    ///   - missingOwnerID: The missing-or-invalid `owner_id` message.
    ///   - invalidOwnerIDLength: The `owner_id` length-validation message.
    public init(missingOwnerID: String, invalidOwnerIDLength: String) {
        self.missingOwnerID = missingOwnerID
        self.invalidOwnerIDLength = invalidOwnerIDLength
    }
}
