import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import CmuxNextWakeups
public import Foundation
import os

/// The app's copies of the signed flags document in Application Support: the
/// last accepted one and the last known good one, as Chrome's
/// `VariationsSeedStore` keeps the latest and the safe seed
/// (components/variations/variations_seed_store.cc). Each copy is one file
/// that holds the document's bytes with their signature and is replaced
/// atomically, as Chrome keeps the seed and its signature in one Local State
/// write: a reader never sees new bytes under an old signature. The signature
/// is verified again on every read, so an edited file counts for nothing (as
/// cmux-tui `feature_flags.rs` does).
///
/// The newest document that verifies, parses and is not a rollback is stored
/// whole, even when it has expired or excludes this build. Chrome stores the
/// latest seed and filters its studies only when it uses them
/// (components/variations/study_filtering.cc); here too the newest document
/// decides what this build gets, so a narrowed build range or a passed expiry
/// takes an older document's overrides back. ``overrides(of:)`` filters.
///
/// Every file read and write is posted to ``BackgroundWork``'s files lane at
/// one fixed priority (``lanePriority``), never raised to the caller's. The
/// files lane runs one item per priority in post order (`LaneScheduler`'s
/// `perPriority` policy), so the rollback check and the write of one store
/// never interleave with another store, a promotion or a load. The fetch
/// hands verified bytes to ``store(_:)``; they
/// apply at the next launch, where the composition root reads both copies
/// with ``load()`` and safe mode (task 094) picks one.
public nonisolated final class FeatureRemoteStore: Sendable {
    /// One document as fetched: its bytes and their base64 signature. On disk,
    /// a JSON object with `data` (base64) and `signature`.
    public struct Copy: Sendable, Equatable, Codable {
        public let data: Data
        public let signature: String

        public init(data: Data, signature: String) {
            self.data = data
            self.signature = signature
        }
    }

    /// A copy read back from disk, its signature verified, with the document it holds for this cohort.
    public struct Stored: Sendable, Equatable {
        public let copy: Copy
        public let document: FeatureRemoteDocument

        public init(copy: Copy, document: FeatureRemoteDocument) {
            self.copy = copy
            self.document = document
        }
    }

    /// Both copies at launch; nil where none is stored or the stored one does not verify or parse.
    public struct Launch: Sendable, Equatable {
        public let last: Stored?
        public let lastKnownGood: Stored?

        public init(last: Stored?, lastKnownGood: Stored?) {
            self.last = last
            self.lastKnownGood = lastKnownGood
        }
    }

    /// Which copy a file holds.
    public enum Slot: String, Sendable, CaseIterable {
        /// The last document ``store(_:)`` accepted.
        case last = "flags"
        /// The copy safe mode falls back to (``promoteLastKnownGood(_:)``).
        case lastKnownGood = "flags-last-known-good"
    }

    /// Why a copy was not written.
    public enum WriteError: Error, Sendable, Equatable, CustomStringConvertible {
        /// The document itself is refused.
        case rejected(FeatureRemoteDocumentError)
        /// The file system refused, or shutdown dropped the write (the reason says why).
        case io(String)

        public var description: String {
            switch self {
            case .rejected(let error): "rejected: \(error)"
            case .io(let reason): "not written: \(reason)"
            }
        }
    }

    /// The one priority of every file operation of the store: `load()` runs
    /// at launch, where a person waits, and a store must never pass it.
    public static let lanePriority = WorkPriority.userVisible

    /// The directory of the copies: `<Application Support>/<app folder>/features`.
    public let directory: URL
    public let context: FeatureRemoteContext
    private let work: BackgroundWork
    private let signatures: FeatureRemoteSignatureCheck
    private let now: @Sendable () -> Date
    private let report: @Sendable (String) -> Void

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "features")

    /// - Parameters:
    ///   - directory: where the copies live; created on the first write.
    ///   - context: the registry, cohort and build every document is checked against.
    ///   - work: the app's ``BackgroundWork``; every file operation runs on its files lane.
    ///   - signatures: the trusted keys.
    ///   - now: the wall clock `FeaturesExpiresAt` is compared with.
    ///   - report: gets each refused document, each document not applied to this build and each
    ///     ignored entry as a line, after the unified log (subsystem `com.cmuxterm.app.next`,
    ///     category `features`) has it; tests read it.
    public init(
        directory: URL,
        context: FeatureRemoteContext,
        work: BackgroundWork,
        signatures: FeatureRemoteSignatureCheck,
        now: @escaping @Sendable () -> Date = { Date() },
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.context = context
        self.work = work
        self.signatures = signatures
        self.now = now
        self.report = report
    }

    /// The file of `slot`: `<directory>/<slot>.json`, the encoded ``Copy``.
    public func file(_ slot: Slot) -> URL {
        directory.appending(path: "\(slot.rawValue).json", directoryHint: .notDirectory)
    }

    /// Stores a fetched document as the last copy when it verifies, parses and
    /// its serial is not below the stored copy's; otherwise the stored copy
    /// stays. Returns what the document gives this build (it applies at the
    /// next launch): ``FeatureRemoteOverrides/none``, with the reason logged,
    /// when it has expired or excludes this build.
    @discardableResult
    public func store(_ copy: Copy) async throws(WriteError) -> FeatureRemoteOverrides {
        let outcome = await inOrder(shutdown: .blockShutdown) { [self] in storeOnLane(copy) }
        guard let outcome else { throw .io("not run: shutdown dropped it") }
        for failure in outcome.failures { log(failure, error: true) }
        switch outcome.result {
        case .success(let document):
            return overrides(of: document)
        case .failure(let error):
            log("flags document not stored: \(error)", error: true)
            throw error
        }
    }

    /// Reads, verifies and parses both copies. A copy that is missing, does
    /// not verify or does not parse reads as nil (and is logged); expiry and
    /// the build range are checked by ``overrides(of:)``, so safe mode sees
    /// the copies as they are.
    public func load() async -> Launch {
        let read = await inOrder(shutdown: .skipOnShutdown) { [self] () -> (launch: Launch, failures: [String]) in
            var failures: [String] = []
            let last = readOnLane(.last, failures: &failures)
            let lastKnownGood = readOnLane(.lastKnownGood, failures: &failures)
            return (launch: Launch(last: last, lastKnownGood: lastKnownGood), failures: failures)
        }
        guard let read else { return Launch(last: nil, lastKnownGood: nil) }
        for failure in read.failures { log(failure, error: true) }
        return read.launch
    }

    /// What `stored` gives this build now, or ``FeatureRemoteOverrides/none``
    /// with the reason logged when it has expired or excludes this build.
    public func overrides(of stored: Stored?) -> FeatureRemoteOverrides {
        guard let stored else { return .none }
        return overrides(of: stored.document)
    }

    /// Writes `copy` as the last known good one: the copy this launch ran
    /// with, once the run has fetched successfully (safe mode, task 094).
    public func promoteLastKnownGood(_ copy: Copy) async throws(WriteError) {
        let outcome = await inOrder(shutdown: .blockShutdown) { [self] () -> Result<Void, WriteError> in
            guard signatures.isValid(copy.data, signature: copy.signature) else {
                return .failure(.rejected(.badSignature))
            }
            return write(copy, to: .lastKnownGood)
        }
        guard let outcome else { throw .io("not run: shutdown dropped it") }
        if case .failure(let error) = outcome {
            log("last known good flags document not stored: \(error)", error: true)
            throw error
        }
    }

    private func overrides(of document: FeatureRemoteDocument) -> FeatureRemoteOverrides {
        do {
            let overrides = try FeatureRemoteOverrides(document, context: context, now: now())
            log(ignored: overrides.ignored)
            return overrides
        } catch {
            log("flags document \(document.serial) not applied: \(error)", error: false)
            return .none
        }
    }

    /// Runs `body` on the files lane at ``lanePriority``, after every file
    /// operation of the store posted before it; nil when shutdown dropped it.
    private func inOrder<T: Sendable>(
        shutdown: ShutdownBehavior,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        _ body: @escaping @Sendable () -> T
    ) async -> T? {
        // A continuation dropped without a resume answers nil, as an abandoned lane item does.
        try? await withOnceContinuation { (continuation: OnceContinuation<T?, OnceContinuationError>) in
            work.post(
                Self.lanePriority,
                mayBlock: .files,
                shutdown: shutdown,
                fileID: fileID,
                line: line,
                abandoned: { continuation.resume(returning: nil) }
            ) {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: Lane work (BackgroundWork files lane, through inOrder only)

    /// Refuses only a bad signature, a document that does not parse and a
    /// serial below the stored copy's. A stored copy that does not verify or
    /// parse holds no serial to protect: a write replaces the whole file, so
    /// it can only be a file changed outside the app, and it is reported.
    private func storeOnLane(_ copy: Copy) -> (result: Result<FeatureRemoteDocument, WriteError>, failures: [String]) {
        var failures: [String] = []
        guard signatures.isValid(copy.data, signature: copy.signature) else {
            return (.failure(.rejected(.badSignature)), failures)
        }
        let document: FeatureRemoteDocument
        do throws(FeatureRemoteDocumentError) {
            document = try FeatureRemoteDocument(json: copy.data, cohort: context.cohort)
        } catch {
            return (.failure(.rejected(error)), failures)
        }
        if let stored = readOnLane(.last, failures: &failures), document.serial < stored.document.serial {
            return (.failure(.rejected(.lowerSerial(document: document.serial, stored: stored.document.serial))), failures)
        }
        return (write(copy, to: .last).map { _ in document }, failures)
    }

    private func readOnLane(_ slot: Slot, failures: inout [String]) -> Stored? {
        let copy: Copy
        do {
            let bytes = try Data(blockingContentsOf: file(slot))
            copy = try JSONDecoder().decode(Copy.self, from: bytes)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            failures.append("\(slot) flags document unreadable: \(error)")
            return nil
        }
        guard signatures.isValid(copy.data, signature: copy.signature) else {
            failures.append("\(slot) flags document: \(FeatureRemoteDocumentError.badSignature)")
            return nil
        }
        do {
            let document = try FeatureRemoteDocument(json: copy.data, cohort: context.cohort)
            return Stored(copy: copy, document: document)
        } catch {
            failures.append("\(slot) flags document: \(error)")
            return nil
        }
    }

    /// The bytes and their signature in one file, replaced atomically.
    private func write(_ copy: Copy, to slot: Slot) -> Result<Void, WriteError> {
        do {
            let envelope = try JSONEncoder().encode(copy)
            try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
            try envelope.blockingWrite(to: file(slot), options: .atomic)
            return .success(())
        } catch {
            return .failure(.io(String(describing: error)))
        }
    }

    // MARK: Reporting

    private func log(ignored: [FeatureRemoteIgnoredEntry]) {
        for entry in ignored { log("flags document entry ignored: \(entry)", error: false) }
    }

    private func log(_ line: String, error: Bool) {
        if error {
            Self.logger.error("\(line, privacy: .public)")
        } else {
            Self.logger.notice("\(line, privacy: .public)")
        }
        report(line)
    }
}
