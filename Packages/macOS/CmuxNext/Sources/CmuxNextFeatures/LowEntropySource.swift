public import Foundation
import CmuxNextCompat

/// A stable per-install value in `0..<8000` that picks every field-trial arm:
/// Chromium's low entropy source (components/metrics/entropy_state.cc,
/// `kMaxLowEntropySize = 8000`, stored once in Local State and never changed).
///
/// The value only selects arms. It is never sent: a report carries the arms
/// it picked (``FieldTrials/reportEntries``), never the value.
public nonisolated struct LowEntropySource: Sendable, Hashable, CustomStringConvertible {
    /// The number of values (Chrome's `kMaxLowEntropySize`).
    public static let range = 8000

    /// The value, in `0..<range`.
    public let value: Int

    /// The source `value`, or nil when it is outside `0..<range`.
    public init?(_ value: Int) {
        guard (0..<Self.range).contains(value) else { return nil }
        self.value = value
    }

    /// A new uniformly random value.
    public init(randomUsing generator: inout some RandomNumberGenerator) {
        value = Int.random(in: 0..<Self.range, using: &generator)
    }

    /// The value written as decimal text (the stored form), or nil for any
    /// other text, as Chrome regenerates a stored value outside the range.
    public init?(storedText text: String) {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(value)
    }

    /// The stored form: the value in decimal.
    public var description: String { String(value) }

    /// The stored value, or a new one that is saved first: the value is the
    /// same at every launch of this install. A store that cannot read or
    /// save throws, and the caller then enrolls in no randomized arm (an arm
    /// that changes per launch would mix both arms' data in one install).
    /// Blocking: call it off the main thread (BackgroundWork `.files`).
    public static func loadOrCreate(
        from store: any LowEntropySourceStore,
        using generator: inout some RandomNumberGenerator
    ) throws(LowEntropySourceError) -> LowEntropySource {
        if let text = try store.load(), let stored = LowEntropySource(storedText: text) { return stored }
        let created = LowEntropySource(randomUsing: &generator)
        try store.save(created.description)
        return created
    }
}

/// Where the ``LowEntropySource`` is kept. Both calls may block on the disk.
public protocol LowEntropySourceStore: Sendable {
    /// The stored text, or nil when nothing is stored yet.
    func load() throws(LowEntropySourceError) -> String?
    /// Replaces the stored text.
    func save(_ text: String) throws(LowEntropySourceError)
}

/// Why the low entropy source could not be read or kept.
public nonisolated enum LowEntropySourceError: Error, Sendable, Hashable, CustomStringConvertible {
    case readFailed(String)
    case saveFailed(String)

    public var description: String {
        switch self {
        case let .readFailed(reason): "low entropy source: read failed: \(reason)"
        case let .saveFailed(reason): "low entropy source: save failed: \(reason)"
        }
    }
}

extension LowEntropySource {
    /// A store of one file, written atomically (the composition root puts it
    /// in the build's Application Support directory).
    public nonisolated struct FileStore: LowEntropySourceStore {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        public func load() throws(LowEntropySourceError) -> String? {
            do {
                let data = try Data(blockingContentsOf: url)
                return String(decoding: data, as: UTF8.self)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            } catch {
                throw LowEntropySourceError.readFailed(String(describing: error))
            }
        }

        public func save(_ text: String) throws(LowEntropySourceError) {
            do {
                try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((text + "\n").utf8).blockingWrite(to: url, options: .atomic)
            } catch {
                throw LowEntropySourceError.saveFailed(String(describing: error))
            }
        }
    }
}
