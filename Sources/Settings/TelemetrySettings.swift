import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum TelemetrySettings {
    static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"
    static let defaultSendAnonymousTelemetry = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: sendAnonymousTelemetryKey) == nil {
            return defaultSendAnonymousTelemetry
        }
        return defaults.bool(forKey: sendAnonymousTelemetryKey)
    }

    // Freeze telemetry enablement once per launch. Settings changes apply on next restart.
    static let enabledForCurrentLaunch = isEnabled()
}
