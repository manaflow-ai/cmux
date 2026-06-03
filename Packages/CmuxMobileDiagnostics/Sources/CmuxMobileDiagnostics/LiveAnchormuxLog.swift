import Foundation

/// Debug-only logging helper shared across the mobile packages (terminal, sync,
/// UI). Routes to `NSLog` and, on iOS DEBUG builds, into the in-app ring buffer
/// (``MobileDebugLog``) so a dogfooder can copy the log off-device.
///
/// The message closure is only evaluated in DEBUG builds, so release builds pay
/// nothing for instrumented call sites.
///
/// - Parameter message: An autoclosure producing the line to log.
@inline(__always)
public func liveAnchormuxLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    let msg = message()
    NSLog("cmux.terminal.anchormux %@", msg)
    #if canImport(UIKit)
    MobileDebugLog.shared.append(msg)
    #endif
    #endif
}
