import Foundation
#if canImport(UIKit)
import Synchronization
import UIKit
#endif

/// Debug-only logging shim shared across the mobile packages (terminal, sync,
/// UI). Routes to `NSLog` and, on iOS DEBUG builds, into the in-app ring buffer
/// so a dogfooder can copy the log off-device.
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

#if canImport(UIKit) && DEBUG
/// In-app ring buffer of recent debug log lines (iOS DEV builds only).
///
/// Thread-safe via a Swift `Mutex` (it is fed from Ghostty IO/render threads),
/// so it is genuinely `Sendable` without opting out of concurrency checking.
public final class MobileDebugLog: Sendable {
    public static let shared = MobileDebugLog()

    private let buffer = Mutex<[String]>([])
    private let capacity = 4000
    private let startedAt = Date()

    private init() {}

    /// Append one timestamped line (seconds since the buffer was created).
    public func append(_ message: String) {
        let elapsed = String(format: "%9.3f", Date().timeIntervalSince(startedAt))
        let capacity = capacity
        buffer.withLock { lines in
            lines.append("[\(elapsed)] \(message)")
            if lines.count > capacity {
                lines.removeFirst(lines.count - capacity)
            }
        }
    }

    /// The full buffer as newline-joined text, newest last.
    public func snapshot() -> String {
        buffer.withLock { $0.joined(separator: "\n") }
    }

    public func clear() {
        buffer.withLock { $0.removeAll(keepingCapacity: true) }
    }

    /// Copy the buffer to the system pasteboard, optionally prefixed with a
    /// section (e.g. the visible terminal text). Returns the line count copied.
    @MainActor
    @discardableResult
    public func copyToPasteboard(prepending: String? = nil) -> Int {
        let (count, body) = buffer.withLock { ($0.count, $0.joined(separator: "\n")) }
        let header = "cmux iOS debug log — \(count) lines\n" + String(repeating: "=", count: 40) + "\n"
        var out = ""
        if let prepending, !prepending.isEmpty {
            out += prepending + "\n\n"
        }
        out += header + body
        UIPasteboard.general.string = out
        return count
    }
}
#endif
