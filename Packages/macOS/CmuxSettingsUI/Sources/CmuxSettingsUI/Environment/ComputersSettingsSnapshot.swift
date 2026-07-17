import Foundation

/// One computer row for the **Computers** settings section.
///
/// The host merges the device registry, the local paired-computer store, and
/// live presence into these value snapshots (the settings package stays
/// Foundation-only, so it never sees the transport/registry types).
public struct ComputersSettingsComputer: Sendable, Equatable, Identifiable {
    /// How the row's presence indicator should render.
    public enum Presence: Sendable, Equatable {
        /// The presence service reports the computer online now.
        case online
        /// The presence service reports it offline; `lastSeenAt` when known.
        case offline(lastSeenAt: Date?)
        /// No live presence data; `lastSeenAt` is the registry hint.
        case unknown(lastSeenAt: Date?)
    }

    /// Stable device id (the registry `deviceId`).
    public let deviceID: String
    /// Display name for the row.
    public let name: String
    /// SF Symbol for the device kind, chosen by the host (`desktopcomputer`,
    /// `iphone`, …).
    public let symbolName: String
    /// Whether this row is the Mac the app runs on.
    public let isThisMac: Bool
    /// Whether a local pairing exists for this computer.
    public let isPaired: Bool
    /// Whether the row can be paired from here (a host platform with routes,
    /// not this Mac, not already paired).
    public let canPair: Bool
    /// Presence indicator state.
    public let presence: Presence
    /// Optional secondary line (build channel / instance tag), pre-formatted
    /// by the host.
    public let detail: String?

    public var id: String { deviceID }

    /// Creates a computer row snapshot.
    public init(
        deviceID: String,
        name: String,
        symbolName: String,
        isThisMac: Bool,
        isPaired: Bool,
        canPair: Bool,
        presence: Presence,
        detail: String? = nil
    ) {
        self.deviceID = deviceID
        self.name = name
        self.symbolName = symbolName
        self.isThisMac = isThisMac
        self.isPaired = isPaired
        self.canPair = canPair
        self.presence = presence
        self.detail = detail
    }
}

/// The Computers section's full state snapshot.
public struct ComputersSettingsSnapshot: Sendable, Equatable {
    /// Whether a user is signed in (the registry list requires an account).
    public let isSignedIn: Bool
    /// Merged computer rows in display order.
    public let computers: [ComputersSettingsComputer]
    /// Whether the most recent registry refresh failed (rows may be stale or
    /// local-only).
    public let lastRefreshFailed: Bool

    /// Creates a snapshot.
    public init(
        isSignedIn: Bool,
        computers: [ComputersSettingsComputer],
        lastRefreshFailed: Bool = false
    ) {
        self.isSignedIn = isSignedIn
        self.computers = computers
        self.lastRefreshFailed = lastRefreshFailed
    }
}

/// Result of a pair action (registry row or entered code), rendered inline.
public enum ComputersPairResult: Sendable, Equatable {
    /// Paired; the row list refreshes via the snapshot stream.
    case paired
    /// The pasted text is not a cmux pairing link.
    case invalidLink
    /// No computer currently advertises the entered pairing code (mistyped,
    /// expired, or the other Mac stopped showing it).
    case codeNotFound
    /// Every advertised route points back at this Mac.
    case loopbackRejected
    /// The link belongs to a different account.
    case accountMismatch
    /// The computer advertises no dialable route to persist.
    case noRoutes
    /// The pairing could not be saved.
    case failed
}

/// Result of minting this Mac's pairing code, rendered inline under the
/// "Pair This Mac" row.
public enum ComputersPairingCodeMintResult: Sendable, Equatable {
    /// The code is being advertised; show it until `expiresAt`.
    case minted(code: String, expiresAt: Date)
    /// This Mac has no Tailscale route another Mac could dial.
    case needsTailscale
    /// Pairing requires the Mac to be signed in.
    case signedOut
    /// The pairing listener or registry publish failed.
    case failed
}
