import CmuxTerminalSizing

/// Who this Mac is when it joins a shared terminal.
///
/// The user id is the verified Stack user id of the signed-in account. It is
/// `nil` while signed out; the engine then keys priority by participant id.
public struct TerminalSharingIdentity: Hashable, Sendable {
    /// Verified Stack user id, or `nil` when signed out.
    public var userID: String?
    /// The account's display name, if any.
    public var displayName: String?
    /// The Mac's user-visible computer name.
    public var deviceName: String?

    /// Creates an identity.
    ///
    /// - Parameters:
    ///   - userID: verified Stack user id.
    ///   - displayName: the account's display name.
    ///   - deviceName: the Mac's computer name.
    public init(userID: String? = nil, displayName: String? = nil, deviceName: String? = nil) {
        self.userID = userID
        self.displayName = displayName
        self.deviceName = deviceName
    }

    /// The actor recorded on a `detached` event this Mac causes.
    public var detachActor: TerminalDetachActor {
        TerminalDetachActor(userID: userID, displayName: displayName, deviceName: deviceName)
    }

    /// A participant for this identity.
    ///
    /// - Parameters:
    ///   - id: host-scoped participant id.
    ///   - deviceKind: the kind of device the view runs on.
    ///   - deviceName: overrides ``deviceName`` (a phone reports its own name).
    ///   - viewport: the view's grid, if known.
    ///   - via: relay participant id, if any.
    /// - Returns: the participant.
    public func participant(
        id: String,
        deviceKind: TerminalDeviceKind,
        deviceName: String? = nil,
        viewport: TerminalGridSize? = nil,
        via: String? = nil
    ) -> TerminalSizingParticipant {
        TerminalSizingParticipant(
            id: id,
            userID: userID,
            displayName: displayName,
            deviceKind: deviceKind,
            deviceName: deviceName ?? self.deviceName,
            via: via,
            viewport: viewport
        )
    }
}
