// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The environment upstream Cua Driver must run with inside the helper.
///
/// - `CUA_DRIVER_RS_TELEMETRY_ENABLED=0`, `CUA_TELEMETRY_ENABLED=false`:
///   upstream posts usage events to trycua's PostHog by default.
/// - `CUA_DRIVER_RS_UPDATE_CHECK=false`: no GitHub releases request.
/// - `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=100`: upstream waits up to 1000 ms
///   after every input action for a window change, and phase 0 showed it
///   waits the full time even when the target redraws (Calculator click
///   1141 ms). 50 ms measured 134 ms clicks; 100 ms keeps a 2x margin for a
///   new window or sheet to appear, at about 50 ms per action.
/// - `CUA_DRIVER_HOST_BUNDLE_ID`: the helper's bundle id, so
///   check_permissions names the helper as the attributed host.
public struct HelperEnvironment: Sendable {
    public let helperBundleID: String

    public init(helperBundleID: String) { self.helperBundleID = helperBundleID }

    static let windowChangeTimeoutMilliseconds = 100

    public var required: [String: String] {
        [
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_TELEMETRY_ENABLED": "false",
            "CUA_DRIVER_RS_UPDATE_CHECK": "false",
            "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": String(Self.windowChangeTimeoutMilliseconds),
            "CUA_DRIVER_HOST_BUNDLE_ID": helperBundleID,
        ]
    }

    /// Forces the required values into this process before the driver loads
    /// (whatever the launcher passed). Call before any thread starts.
    public func apply() {
        for (name, value) in required { setenv(name, value, 1) }
    }
}
