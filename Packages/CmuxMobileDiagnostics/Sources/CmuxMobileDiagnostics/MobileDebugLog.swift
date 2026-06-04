import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// In-app debug-log facade for iOS DEV builds, backed by an actor sink.
///
/// This is the thin compatibility surface the mobile packages call into
/// (``append(_:)`` from the synchronous ``MobileDebugLog.anchormux(_:)`` helper, and
/// ``copyToPasteboard(prepending:)`` from the debug menu). The actual buffer
/// and its synchronization live in ``MobileDebugLogSink`` (an `actor`), so this
/// type holds no mutable state of its own; it only bridges synchronous callers
/// into the actor.
///
/// - Note: The ``shared`` instance is a TRANSITIONAL (iOS refactor) shim so the
///   many existing render/IO-thread call sites stay one-liners. The intended
///   end state injects a ``MobileDebugLogSink`` from the app composition root.
public struct MobileDebugLog: Sendable {
    /// Process-wide instance used by the legacy anchormux call sites.
    // TRANSITIONAL (iOS refactor): call sites still reach for `.shared`; the
    // composition root should inject the sink once decomposition reaches them.
    public static let shared = MobileDebugLog(sink: MobileDebugLogSink())

    /// The actor that owns the ring buffer and broadcast stream.
    public let sink: MobileDebugLogSink

    /// Wrap an existing sink.
    ///
    /// - Parameter sink: The actor-backed buffer to bridge synchronous calls to.
    public init(sink: MobileDebugLogSink) {
        self.sink = sink
    }

    /// Append one line, dispatching the write into the actor.
    ///
    /// Safe to call from any thread (Ghostty IO/render). The write is enqueued
    /// on the actor and does not block the caller.
    public func append(_ message: String) {
        let sink = sink
        Task { await sink.append(message) }
    }

    /// Identifies the running build so a pasted log proves which reload it came
    /// from: the bundle name (carries the `--tag`, e.g. "cmux DEV grid") plus
    /// the executable's build timestamp (changes on every rebuild). All dev
    /// builds share `CFBundleVersion = 1`, so the exec mtime is the only signal
    /// that distinguishes one reload from the next.
    static let buildStamp: String = {
        var parts: [String] = []
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            parts.append(name)
        }
        if let exec = Bundle.main.executableURL,
           let mtime = (try? FileManager.default.attributesOfItem(atPath: exec.path))?[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            parts.append("built \(formatter.string(from: mtime))")
        }
        return parts.isEmpty ? "build ?" : parts.joined(separator: " · ")
    }()

    #if canImport(UIKit)
    /// Copy the buffer to the system pasteboard, optionally prefixed with a
    /// section (e.g. the visible terminal text).
    ///
    /// - Parameter prepending: Optional text written above the log header.
    /// - Returns: The number of buffered lines copied.
    @MainActor
    @discardableResult
    public func copyToPasteboard(prepending: String? = nil) async -> Int {
        let (count, body) = await sink.snapshotWithCount()
        let header = "cmux iOS debug log — \(count) lines · \(Self.buildStamp)\n"
            + String(repeating: "=", count: 40) + "\n"
        var out = ""
        if let prepending, !prepending.isEmpty {
            out += prepending + "\n\n"
        }
        out += header + body
        UIPasteboard.general.string = out
        return count
    }
    #endif
}
