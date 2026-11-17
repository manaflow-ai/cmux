import CmuxNextCompat
public import Foundation
import os

/// An Objective-C exception that ended a run: what the app's `run.exception` file holds
/// (crash-elimination class b: NSRangeException, unrecognized selector).
///
/// Holds the exception's name, reason and call stack frames only; the reason is AppKit's text and
/// the frames are "image function + offset" lines (``StackSymbolicator``).
public struct RecordedException: Codable, Equatable, Sendable {
    /// Frames kept from the exception's call stack.
    public static let frameLimit = 64

    /// The exception's name, as `NSRangeException`.
    public var name: String
    /// The exception's reason, as AppKit wrote it.
    public var reason: String
    /// The throw's call stack, innermost first, at most ``frameLimit`` lines.
    public var frames: [String]

    /// An exception with the given parts.
    public init(name: String, reason: String, frames: [String]) {
        self.name = name
        self.reason = reason
        self.frames = frames
    }

    /// `exception`, with up to ``frameLimit`` frames named through the app symbol map
    /// (`callStackSymbols` has no names for the release executable, which ships stripped).
    public init(_ exception: NSException) {
        let addresses = exception.callStackReturnAddresses.prefix(Self.frameLimit).map { $0.uintValue }
        let frames = addresses.isEmpty ? Array(exception.callStackSymbols.prefix(Self.frameLimit))
            : StackSymbolicator().frames(for: addresses).map(\.description)
        self.init(name: exception.name.rawValue, reason: exception.reason ?? "", frames: frames)
    }

    /// "NSRangeException: <reason>", trimmed to one line for the notice.
    public var summary: String {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = line.isEmpty ? name : "\(name): \(line)"
        return text.count > 200 ? String(text.prefix(199)) + "…" : text
    }

    /// Encodes this record into `url`; a failure is logged as a fault (the process is ending).
    public func write(to url: URL) {
        do {
            try JSONEncoder().encode(self).blockingWrite(to: url, options: .atomic)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
                .fault("uncaught exception record write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The record in `url`, or nil when there is none or it does not decode (read once at launch).
    public static func read(from url: URL) -> RecordedException? {
        guard let data = try? Data(blockingContentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordedException.self, from: data)
    }
}
