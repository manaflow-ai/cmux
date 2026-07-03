import AppKit
import Foundation

struct WorkspaceDeferredThemeRefresh {
    let reason: String
    let backgroundOverride: NSColor?
    let backgroundEventId: UInt64?
    let backgroundSource: String?
    let notificationPayloadHex: String?
    let forceInitialApply: Bool
}
