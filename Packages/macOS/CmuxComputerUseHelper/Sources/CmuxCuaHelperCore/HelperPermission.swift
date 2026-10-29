// SPDX-License-Identifier: GPL-3.0-or-later
import ApplicationServices
import CoreGraphics
import Foundation

/// One grant requested by the person's Computer Use setup button. Only the
/// app's private control pipe accepts this request, never the agent socket.
public enum HelperPermission: String, Sendable {
    case accessibility
    case screenRecording = "screen_recording"

    @MainActor public func request() -> Bool {
        switch self {
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        }
    }
}
