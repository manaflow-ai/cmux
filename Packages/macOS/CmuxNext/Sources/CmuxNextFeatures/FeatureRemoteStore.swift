import CmuxNextCompat
public import CmuxNextWakeups
public import Foundation
import os

/// The app's copies of the signed flags document in Application Support: the
/// last accepted one and the last known good one, as Chrome's
/// `VariationsSeedStore` keeps the latest and the safe seed
/// (components/variations/variations_seed_store.cc). Each copy is the
/// document's bytes with their signature, verified again on every read, so an
/// edited file counts for nothing (as cmux-tui `feature_flags.rs` does).
///
/// Every file read and write runs on ``BackgroundWork``'s files lane, never on
/// the caller's thread. The fetch (task p12-perf-process-093) hands verified
/// bytes to ``store(_:)``; they apply at the next launch, where the composition
/// root reads both copies with ``load()`` and safe mode (task 094) picks one.
public nonisolated final class FeatureRemoteStore: Sendable {
    /// One document as fetched: its bytes and their base64 signature.
    public struct Copy: Sendable, Equatable {
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

    /// Which copy a file pair holds.
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
        /// The file system refused (the reason says why).
        case io(String)

        public var description: String {
            switch self {
            case .rejected(let error): "rejected: \(error)"
            case .io(let reason): "not written: \(reason)"
            }
        }
    }

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
    ///   - report: gets each refused document and ignored entry as a line, after the unified log
    ///     (subsystem `com.cmuxterm.app.next`, category `features`) has it; tests read it.
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

    /// The flags document (`<directory>/<slot>.json`) and its signature (`.json.sig`).
    public func files(_ slot: Slot) -> (data: URL, signature: URL) {
        let data = directory.appending(path: "\(slot.rawValue).json", directoryHint: .notDirectory)
        return (data, directory.appending(path: "\(slot.rawValue).json.sig", directoryHint: .notDirectory))
    }

    /// Stores a fetched document as the last copy when it verifies, parses,
    /// applies to this build now and its serial is not below the stored
    /// copy's; otherwise the stored copy stays. Returns what the document
    /// gives this build (it applies at the next launch).
    @discardableResult
    public func store(_ copy: Copy) async throws(WriteError) -> FeatureRemoteOverrides {
        let outcome: Result<FeatureRemoteOverrides, WriteError>
        do {
            outcome = try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { [self] in
                storeOnLane(copy)
            }
        } catch {
            // Shutdown dropped it or the caller was cancelled before it ran: nothing was written.
            throw .io("not run: \(error)")
        }
        switch outcome {
        case .success(let overrides):
            log(ignored: overrides.ignored)
            return overrides
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
        let read: (launch: Launch, failures: [String])
        do {
            read = try await work.run(.userVisible, mayBlock: .files) { [self] in
                var failures: [String] = []
                let last = readOnLane(.last, failures: &failures)
                let lastKnownGood = readOnLane(.lastKnownGood, failures: &failures)
                return (launch: Launch(last: last, lastKnownGood: lastKnownGood), failures: failures)
            }
        } catch {
            return Launch(last: nil, lastKnownGood: nil)
        }
        for failure in read.failures { log(failure, error: true) }
        return read.launch
    }

    /// What `stored` gives this build now, or ``FeatureRemoteOverrides/none``
    /// with the reason logged when it has expired or excludes this build.
    public func overrides(of stored: Stored?) -> FeatureRemoteOverrides {
        guard let stored else { return .none }
        do {
            let overrides = try FeatureRemoteOverrides(stored.document, context: context, now: now())
            log(ignored: overrides.ignored)
            return overrides
        } catch {
            log("flags document \(stored.document.serial) not applied: \(error)", error: false)
            return .none
        }
    }

    /// Writes `copy` as the last known good one: the copy this launch ran
    /// with, once the run has fetched successfully (safe mode, task 094).
    public func promoteLastKnownGood(_ copy: Copy) async throws(WriteError) {
        let outcome: Result<Void, WriteError>
        do {
            outcome = try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { [self] () -> Result<Void, WriteError> in
                guard signatures.isValid(copy.data, signature: copy.signature) else {
                    return .failure(.rejected(.badSignature))
                }
                return write(copy, to: .lastKnownGood)
            }
        } catch {
            throw .io("not run: \(error)")
        }
        if case .failure(let error) = outcome {
            log("last known good flags document not stored: \(error)", error: true)
            throw error
        }
    }

    // MARK: Lane work (BackgroundWork files lane only)

    private func storeOnLane(_ copy: Copy) -> Result<FeatureRemoteOverrides, WriteError> {
        guard signatures.isValid(copy.data, signature: copy.signature) else { return .failure(.rejected(.badSignature)) }
        let overrides: FeatureRemoteOverrides
        do throws(FeatureRemoteDocumentError) {
            let document = try FeatureRemoteDocument(json: copy.data, cohort: context.cohort)
            // A stored copy that no longer verifies or parses holds no serial to protect.
            var unreadable: [String] = []
            if let stored = readOnLane(.last, failures: &unreadable), document.serial < stored.document.serial {
                return .failure(.rejected(.lowerSerial(document: document.serial, stored: stored.document.serial)))
            }
            overrides = try FeatureRemoteOverrides(document, context: context, now: now())
        } catch {
            return .failure(.rejected(error))
        }
        return write(copy, to: .last).map { _ in overrides }
    }

    private func readOnLane(_ slot: Slot, failures: inout [String]) -> Stored? {
        let paths = files(slot)
        let data: Data
        let signature: String
        do {
            data = try Data(blockingContentsOf: paths.data)
            signature = try String(blockingContentsOf: paths.signature, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            failures.append("\(slot) flags document unreadable: \(error)")
            return nil
        }
        guard signatures.isValid(data, signature: signature) else {
            failures.append("\(slot) flags document: \(FeatureRemoteDocumentError.badSignature)")
            return nil
        }
        do {
            let document = try FeatureRemoteDocument(json: data, cohort: context.cohort)
            return Stored(copy: Copy(data: data, signature: signature), document: document)
        } catch {
            failures.append("\(slot) flags document: \(error)")
            return nil
        }
    }

    /// The signature first, then the document, each replaced atomically: a
    /// crash between the two leaves a pair that does not verify (read as no
    /// copy), never an old signature over new bytes.
    private func write(_ copy: Copy, to slot: Slot) -> Result<Void, WriteError> {
        let paths = files(slot)
        do {
            try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(copy.signature.utf8).blockingWrite(to: paths.signature, options: .atomic)
            try copy.data.blockingWrite(to: paths.data, options: .atomic)
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
