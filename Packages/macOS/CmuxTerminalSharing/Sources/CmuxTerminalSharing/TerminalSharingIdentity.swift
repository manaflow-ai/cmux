import CmuxTerminalSizing
import CryptoKit
import Foundation

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
    /// This Mac's stable sizing device id (see ``sizingDeviceID(installID:)``).
    public var deviceID: String?

    /// Creates an identity.
    ///
    /// - Parameters:
    ///   - userID: verified Stack user id.
    ///   - displayName: the account's display name.
    ///   - deviceName: the Mac's computer name.
    ///   - deviceID: this Mac's stable sizing device id.
    public init(userID: String? = nil, displayName: String? = nil, deviceName: String? = nil, deviceID: String? = nil) {
        self.userID = userID
        self.displayName = displayName
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    /// The sizing `device_id` for an install id: a short one-way digest, so
    /// the size state other workspace members see never carries the Mac's
    /// pairing identity, while every view from one Mac shares one key.
    ///
    /// - Parameter installID: the Mac's persistent host device id.
    /// - Returns: 16 lowercase hex characters.
    public static func sizingDeviceID(installID: String) -> String {
        let digest = SHA256.hash(data: Data("cmux.terminal-sizing.device:\(installID)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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
    /// - Returns: the participant. A phone passes its own `deviceName`, and
    ///   then this Mac's ``deviceID`` is not used.
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
            deviceID: deviceName == nil ? deviceID : nil,
            via: via,
            viewport: viewport
        )
    }
}
