internal import Foundation

/// A change to this phone's `counts_override` carried by a viewport report.
public enum MobileTerminalCountsOverrideChange: Equatable, Sendable {
    /// Leave the host's value alone: the key is omitted.
    case unchanged
    /// Set an explicit value.
    case set(Bool)
    /// Clear the override back to the automatic rule: the key is `null`.
    case clear
}

/// Builds `mobile.terminal.viewport` parameters.
///
/// `counts_override` is omitted unless the user changed it, because `null`
/// clears the override and would undo "Reattach as viewer" on every resize.
public struct MobileTerminalViewportParameters {
    private init() {}

    /// Parameters for a viewport report.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace id.
    ///   - surfaceID: The terminal surface id.
    ///   - clientID: This phone's client id.
    ///   - viewport: The phone's natural grid.
    ///   - generation: The monotonic viewport generation.
    ///   - identity: `device_kind` and `device_name`.
    ///   - countsOverride: The counts override change, if any.
    /// - Returns: The JSON-ready parameter dictionary.
    public static func report(
        workspaceID: String,
        surfaceID: String,
        clientID: String,
        viewport: MobileTerminalViewportSize,
        generation: UInt64,
        identity: MobileTerminalDeviceIdentity,
        countsOverride: MobileTerminalCountsOverrideChange = .unchanged
    ) -> [String: Any] {
        var params: [String: Any] = [
            "workspace_id": workspaceID,
            "surface_id": surfaceID,
            "client_id": clientID,
            "viewport_columns": viewport.columns,
            "viewport_rows": viewport.rows,
            "viewport_generation": Int(clamping: generation),
            "device_kind": identity.kind.rawValue,
            "device_name": identity.name,
        ]
        switch countsOverride {
        case .unchanged:
            break
        case let .set(value):
            params["counts_override"] = value
        case .clear:
            params["counts_override"] = NSNull()
        }
        return params
    }

    /// The viewport fields a `mobile.terminal.replay` request carries, so the
    /// host can register this phone with its viewport and identity and apply
    /// the shared size BEFORE it captures the replay. The first frame is then
    /// already sized to the settled grid.
    ///
    /// Empty without a viewport: `client_id` and the dimensions travel
    /// together or not at all.
    /// - Parameters:
    ///   - clientID: This phone's client id.
    ///   - viewport: The phone's latest natural grid, if measured.
    ///   - generation: The viewport generation of that grid, if allocated.
    ///   - identity: `device_kind` and `device_name`.
    /// - Returns: The JSON-ready fields to merge into the replay parameters.
    public static func replay(
        clientID: String,
        viewport: MobileTerminalViewportSize?,
        generation: UInt64?,
        identity: MobileTerminalDeviceIdentity
    ) -> [String: Any] {
        guard let viewport, viewport.columns > 0, viewport.rows > 0 else { return [:] }
        var params: [String: Any] = [
            "client_id": clientID,
            "viewport_columns": viewport.columns,
            "viewport_rows": viewport.rows,
            "device_kind": identity.kind.rawValue,
            "device_name": identity.name,
        ]
        if let generation {
            params["viewport_generation"] = Int(clamping: generation)
        }
        return params
    }
}

