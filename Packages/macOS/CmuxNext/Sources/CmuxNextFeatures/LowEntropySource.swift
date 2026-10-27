import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation
import os

/// This install's low-entropy value, 0 ..< 8000: Chrome's low entropy source
/// (components/metrics/entropy_state.cc, `kMaxLowEntropySize = 8000`). It is
/// drawn once at random and kept in the features folder, so every study a
/// person is in keeps its arm from launch to launch (``FieldTrials``).
///
/// The value is small on purpose, as in Chrome: it picks arms, and 8000
/// values cannot tell one install from another.
public nonisolated struct LowEntropySource: Sendable, Hashable, CustomStringConvertible {
    /// The number of values (`kMaxLowEntropySize`).
    public static let domain = 8000

    public let value: Int

    /// Nil when `value` is outside 0 ..< ``domain``.
    public init?(value: Int) {
        guard (0 ..< Self.domain).contains(value) else { return nil }
        self.value = value
    }

    /// A new value from `generator` (Chrome's `GenerateLowEntropySource`, `base::RandInt`).
    public init(using generator: inout some RandomNumberGenerator) {
        value = Int.random(in: 0 ..< Self.domain, using: &generator)
    }

    public var description: String { "low-entropy=\(value)" }

    /// Where this value falls among all ``domain`` values for `study`: 0 ..< ``domain``. Chrome's
    /// `NormalizedMurmurHashEntropyProvider::GetEntropyForTrial` (components/variations/entropy_provider.cc):
    /// each value is hashed with the study's seed, and the rank is how many values hash below this one.
    /// Every study orders the values its own way, so arms of two studies do not line up, and the ranks
    /// of all values cover 0 ..< ``domain`` once each (two equal hashes share a rank), so an arm's share
    /// of installs is its share of the weights.
    public func rank(forStudy study: String) -> Int {
        let seed = Self.murmur3(study)
        let mine = Self.murmur3(seed: seed, value: UInt16(value))
        var rank = 0
        for other in 0 ..< Self.domain where Self.murmur3(seed: seed, value: UInt16(other)) < mine {
            rank += 1
        }
        return rank
    }

    // MARK: The stored value

    /// Why the stored value was not read or written.
    public enum FileError: Error, Sendable, Equatable, CustomStringConvertible {
        /// The file exists and does not hold a value in 0 ..< 8000; a new one is drawn.
        case unreadable(String)
        /// The file system refused the write; this launch uses the new value, the next draws again.
        case notWritten(String)
        /// Shutdown dropped the item before it ran; this launch uses a value drawn on the caller.
        case notRun

        public var description: String {
            switch self {
            case .unreadable(let reason): "low entropy source unreadable: \(reason)"
            case .notWritten(let reason): "low entropy source not written: \(reason)"
            case .notRun: "low entropy source not read: not run"
            }
        }
    }

    /// The file's name in the features folder.
    public static let fileName = "low-entropy-source.json"

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "features")

    /// The install's value: the one stored in `<directory>/low-entropy-source.json`, else a new one
    /// drawn with `generate` and written there (Chrome's `EntropyState::GetLowEntropySource`, which
    /// draws again when the stored pref is missing or out of range). The read and the write run in one
    /// item on ``BackgroundWork``'s files lane, never on the caller's thread.
    ///
    /// - Parameters:
    ///   - directory: the features folder in Application Support (the one `FeatureRemoteStore` uses).
    ///   - work: the app's ``BackgroundWork``.
    ///   - generate: draws a new value; tests pass a fixed one.
    ///   - report: gets each file failure as a line, after the unified log (subsystem
    ///     `com.cmuxterm.app.next`, category `features`) has it; tests read it.
    public static func load(
        directory: URL,
        work: BackgroundWork,
        generate: @escaping @Sendable () -> LowEntropySource = {
            var generator = SystemRandomNumberGenerator()
            return LowEntropySource(using: &generator)
        },
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> LowEntropySource {
        let file = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        let loaded: (source: LowEntropySource, failures: [FileError])
        do {
            loaded = try await work.sequence("features.low-entropy").run(.userVisible, shutdown: .blockShutdown) {
                var failures: [FileError] = []
                if let stored = Self.readOnLane(file, failures: &failures) { return (source: stored, failures: failures) }
                let drawn = generate()
                if let failure = Self.writeOnLane(drawn, to: file) { failures.append(failure) }
                return (source: drawn, failures: failures)
            }
        } catch {
            loaded = (source: generate(), failures: [.notRun])
        }
        for failure in loaded.failures {
            let line = "\(failure)"
            Self.logger.error("\(line, privacy: .public)")
            report(line)
        }
        return loaded.source
    }

    /// The file's shape: `{"lowEntropySource": 1234}`.
    private struct Stored: Codable {
        let lowEntropySource: Int
    }

    private static func readOnLane(_ file: URL, failures: inout [FileError]) -> LowEntropySource? {
        let data: Data
        do {
            data = try Data(blockingContentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            failures.append(.unreadable(String(describing: error)))
            return nil
        }
        let stored: Stored
        do {
            stored = try JSONDecoder().blockingDecode(Stored.self, from: data)
        } catch {
            failures.append(.unreadable(String(describing: error)))
            return nil
        }
        guard let source = LowEntropySource(value: stored.lowEntropySource) else {
            failures.append(.unreadable("\(stored.lowEntropySource) is outside 0 ..< \(domain)"))
            return nil
        }
        return source
    }

    private static func writeOnLane(_ source: LowEntropySource, to file: URL) -> FileError? {
        do {
            try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(lowEntropySource: source.value)).blockingWrite(to: file, options: .atomic)
            return nil
        } catch {
            return .notWritten(String(describing: error))
        }
    }

    // MARK: Hashing

    /// MurmurHash3 x86_32 of the UTF-8 bytes of `text`, seed 0: a study's seed. Chrome seeds with the
    /// first four bytes of the name's SHA-1 (`variations::HashName`); any fixed hash of the name gives
    /// the same property, independent orders per study.
    static func murmur3(_ text: String) -> UInt32 {
        let bytes = Array(text.utf8)
        var hash: UInt32 = 0
        let blocks = bytes.count / 4
        for block in 0 ..< blocks {
            let at = block * 4
            let word = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
            hash ^= mixWord(word)
            hash = rotateLeft(hash, 13) &* 5 &+ 0xe654_6b64
        }
        var tail: UInt32 = 0
        let rest = bytes.count & 3
        if rest >= 3 { tail ^= UInt32(bytes[blocks * 4 + 2]) << 16 }
        if rest >= 2 { tail ^= UInt32(bytes[blocks * 4 + 1]) << 8 }
        if rest >= 1 {
            tail ^= UInt32(bytes[blocks * 4])
            hash ^= mixWord(tail)
        }
        return finalize(hash ^ UInt32(truncatingIfNeeded: bytes.count))
    }

    /// MurmurHash3 x86_32 of the two little-endian bytes of `value` with `seed`: Chrome's
    /// `VariationsMurmurHash::Hash16`.
    static func murmur3(seed: UInt32, value: UInt16) -> UInt32 {
        finalize((seed ^ mixWord(UInt32(value))) ^ 2)
    }

    private static func mixWord(_ word: UInt32) -> UInt32 {
        rotateLeft(word &* 0xcc9e_2d51, 15) &* 0x1b87_3593
    }

    private static func rotateLeft(_ word: UInt32, _ count: UInt32) -> UInt32 {
        (word << count) | (word >> (32 - count))
    }

    private static func finalize(_ word: UInt32) -> UInt32 {
        var hash = word
        hash ^= hash >> 16
        hash = hash &* 0x85eb_ca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2_ae35
        hash ^= hash >> 16
        return hash
    }
}
