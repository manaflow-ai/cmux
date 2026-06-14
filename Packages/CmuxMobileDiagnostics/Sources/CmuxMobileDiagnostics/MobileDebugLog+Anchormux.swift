import Foundation

extension MobileDebugLog {
    /// Debug-only anchormux instrumentation shared across the mobile packages
    /// (terminal, sync, UI). Routes to `NSLog` and, on iOS DEBUG builds, into
    /// the in-app ring buffer so a dogfooder can copy the log off-device.
    ///
    /// The message closure is only evaluated in DEBUG builds, so release
    /// builds pay nothing for instrumented call sites.
    ///
    /// - Parameter message: An autoclosure producing the line to log.
    @inline(__always)
    public static func anchormux(_ message: @autoclosure () -> String) {
        #if DEBUG
        let msg = message()
        NSLog("cmux.terminal.anchormux %@", msg)
        MobileDebugLog.shared.append(msg)
        #endif
    }
}
