import Foundation
import CryptoKit
import Darwin
import CmuxNextCompat
public import CmuxNextWakeups

/// Downloads, verifies and installs the Chromium runtime pack an app build is
/// pinned to (plans/cmux-next/bundle-size-DESIGN.md section 6.3).
///
/// One installer per app process. ``ensure(_:)`` starts the work, or raises a
/// background prefetch to user priority when a person needs Chromium now;
/// ``states()`` reports progress. Each attempt: wait for a usable network,
/// download (resuming the partial file), check size and sha256 against the
/// pin, list the archive and refuse unsafe entries, unpack into a staging
/// folder, refuse symlinks that leave it, check the code signature of the
/// framework, the shim and every helper (when the pin names a team), remove
/// quarantine, then move the folder into place and write its record. A failed
/// attempt waits the next of `retryDelays` (the last delay repeats), jittered as
/// Chromium's `net::BackoffEntry` jitters so clients that failed together do not
/// retry together, and tries again.
///
/// Tests inject every outside dependency:
///
/// ```swift
/// let installer = ChromiumRuntimeInstaller(
///     pin: pin, store: ChromiumRuntimeStore(root: temporaryFolder),
///     downloader: FakeDownloader(bytes: pack), unpacker: TarChromiumRuntimeUnpacker(),
///     signatures: AlwaysValidSignatures(), network: AlwaysOnline(), retryDelays: [.zero], maxAttempts: 2)
/// let state = await installer.run(.user)
/// ```
public actor ChromiumRuntimeInstaller {
    /// How urgently the pack is wanted.
    public enum Priority: Int, Sendable, Comparable {
        /// A prefetch after launch: waits for a network that is neither
        /// constrained (Low Data Mode) nor expensive.
        case background
        /// A person needs Chromium (a tab asked for it, or Retry): any network.
        case user

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The ledger owner of the wait after a failed attempt.
    public static let retryOwner = "ChromiumRuntimeInstaller.retry"

    /// The pack this app build is pinned to.
    public nonisolated let pin: ChromiumRuntimePin
    /// Where packs live.
    public nonisolated let store: ChromiumRuntimeStore
    private let downloader: any ChromiumRuntimeDownloading
    private let unpacker: any ChromiumRuntimeUnpacking
    private let signatures: any ChromiumRuntimeSignatureChecking
    private let network: any ChromiumRuntimeNetwork
    private let retryDelays: [Duration]
    private let retryRandom: @Sendable () -> Double
    private let maxAttempts: Int?
    private let clock: any Clock<Duration>
    private let ledger: WakeupLedger
    private let keepAlso: @Sendable () -> Set<String>

    /// The current state (also delivered by ``states()``).
    public private(set) var state: ChromiumRuntimeInstallState = .idle
    private var job: Task<Void, Never>?
    private var jobPriority: Priority?
    /// Bumped per job, so a cancelled job's cleanup cannot clear its successor.
    private var generation = 0
    private var listeners: [UUID: AsyncStream<ChromiumRuntimeInstallState>.Continuation] = [:]

    /// Creates an installer; nothing starts until ``ensure(_:)`` or ``run(_:)``.
    ///
    /// - Parameters:
    ///   - pin: The pack to install.
    ///   - store: Where packs live.
    ///   - downloader: Fetches the pack (``URLSessionChromiumRuntimeDownloader`` in the app).
    ///   - unpacker: Lists and extracts it (``TarChromiumRuntimeUnpacker``).
    ///   - signatures: Checks code signatures (``SecCodeChromiumRuntimeSignatureChecker``).
    ///   - network: Waits for a usable path (``PathMonitorChromiumRuntimeNetwork``).
    ///   - retryDelays: Waits between failed attempts; the last one repeats.
    ///     The default backs off from 5 s to 30 min.
    ///   - retryRandom: The ``Backoff`` jitter's draw in 0..<1 (tests pass a constant; 0.5 is no spread).
    ///   - maxAttempts: Stop after this many failed attempts (tests); nil retries while the app runs.
    ///   - clock: Drives the retry waits; tests can pass a clock they control.
    ///   - ledger: Where each retry wait is recorded (reason `backoff`).
    ///   - keepAlso: Pack keys the cleanup after an install must keep besides
    ///     the pinned one (the pack this process already runs, if another).
    public init(pin: ChromiumRuntimePin, store: ChromiumRuntimeStore, downloader: any ChromiumRuntimeDownloading,
                unpacker: any ChromiumRuntimeUnpacking, signatures: any ChromiumRuntimeSignatureChecking,
                network: any ChromiumRuntimeNetwork,
                retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(60), .seconds(300), .seconds(1800)],
                retryRandom: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                maxAttempts: Int? = nil, clock: any Clock<Duration> = ContinuousClock(),
                ledger: WakeupLedger = .shared,
                keepAlso: @escaping @Sendable () -> Set<String> = { [] }) {
        self.pin = pin
        self.store = store
        self.downloader = downloader
        self.unpacker = unpacker
        self.signatures = signatures
        self.network = network
        self.retryDelays = retryDelays.isEmpty ? [.zero] : retryDelays
        self.retryRandom = retryRandom
        self.maxAttempts = maxAttempts
        self.clock = clock
        self.ledger = ledger
        self.keepAlso = keepAlso
    }

    /// The current state, then every change, until the stream is dropped.
    public func states() -> AsyncStream<ChromiumRuntimeInstallState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChromiumRuntimeInstallState.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        listeners[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            // task-owner: drops one listener; nothing waits for it
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    /// Starts installing at `priority`, or raises a running background job.
    /// Returns at once; ``states()`` reports the outcome.
    ///
    /// A background job that is waiting (for the network, or between failed
    /// attempts) restarts at user priority, so a person's request does not
    /// wait for Wi-Fi or a backoff. Its partial download is kept.
    public func ensure(_ priority: Priority) {
        if case .installed = state { return }
        if job != nil, let current = jobPriority {
            guard priority > current else { return }
            jobPriority = priority
            switch state {
            case .waitingForNetwork, .failed, .idle:
                job?.cancel()
            case .downloading, .verifying, .installing, .installed:
                return
            }
        }
        jobPriority = priority
        generation += 1
        let previous = job, current = generation
        // A prefetch is work nobody waits for: its task runs at best effort, so the lanes it awaits are not
        // raised to the launching caller's priority (Chrome's component updater, BEST_EFFORT). A person's
        // request keeps the caller's priority.
        let taskPriority: TaskPriority? = priority == .background ? WorkPriority.bestEffort.taskPriority : nil
        job = Task(priority: taskPriority) { [weak self] in
            await previous?.value
            await self?.runJob(current)
        }
    }

    /// Runs attempts until the pack is installed, the task is cancelled or
    /// `maxAttempts` attempts failed, and returns the final state. ``ensure(_:)``
    /// runs this in a task; tests call it directly.
    @discardableResult
    public func run(_ priority: Priority) async -> ChromiumRuntimeInstallState {
        jobPriority = max(jobPriority ?? priority, priority)
        var failures = 0
        var backoff = Backoff(steps: retryDelays, random: retryRandom)
        // wakeup-allow: backoff: a retry loop, not a poll: each pass first waits for a usable network (an event),
        // then makes one attempt; it ends on success, cancellation or maxAttempts, and a failure waits retryDelays.
        while !Task.isCancelled {
            if let installed = store.installation(key: pin.key) {
                publish(.installed(installed))
                return state
            }
            do {
                try await waitForNetwork()
                let installation = try await attempt()
                publish(.installed(installation))
                store.prune(keeping: keepAlso().union([pin.key]))
                return state
            } catch ChromiumRuntimeInstallError.cancelled {
                return state  // a step stopped before it ran (cancelled, or dropped at quit): no failed attempt
            } catch let error as ChromiumRuntimeInstallError {
                failures += 1
                publish(.failed(error, attempt: failures))
                if let maxAttempts, failures >= maxAttempts { return state }
                do {
                    // concurrency-allow: Backoff.wait is an async clock sleep in this actor after a failure, not a blocking wait.
                    try await backoff.wait(owner: Self.retryOwner, clock: clock, ledger: ledger)
                } catch {
                    return state  // cancelled
                }
            } catch {
                return state  // CancellationError
            }
        }
        return state
    }

    private func runJob(_ current: Int) async {
        await run(jobPriority ?? .background)
        guard generation == current else { return }
        job = nil
        jobPriority = nil
    }

    private func waitForNetwork() async throws {
        let allowsExpensive = (jobPriority ?? .background) == .user
        if await network.isUsable(allowsExpensive: allowsExpensive) { return }
        publish(.waitingForNetwork)
        try await network.waitUntilUsable(allowsExpensive: allowsExpensive)
    }

    /// One download, verify and install.
    private func attempt() async throws -> ChromiumRuntimeInstallation {
        let file = store.partialFile(for: pin)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw ChromiumRuntimeInstallError.filesystem(error.localizedDescription)
        }
        publish(.downloading(received: Self.size(of: file), total: pin.size))
        let total = pin.size
        try await downloader.download(pin.url, to: file, expectedSize: pin.size) { [weak self] received in
            // task-owner: one progress hop per chunk; the actor drops stale ones
            Task { await self?.progress(received, total: total) }
        }
        try Task.checkCancellation()
        publish(.verifying)
        let actual = Self.size(of: file)
        guard actual == pin.size else {
            // A short file resumes next time; a long one can never be right.
            if actual > pin.size { try? FileManager.default.removeItem(at: file) }
            throw ChromiumRuntimeInstallError.sizeMismatch(expected: pin.size, actual: actual)
        }
        guard Self.sha256(of: file) == pin.sha256 else {
            try? FileManager.default.removeItem(at: file)
            throw ChromiumRuntimeInstallError.checksumMismatch
        }
        publish(.installing)
        try Self.checkEntries(try await unpacker.entries(of: file), folder: pin.folder)
        let staging: URL
        do { staging = try store.makeStagingDirectory() } catch { throw ChromiumRuntimeInstallError.filesystem(error.localizedDescription) }
        do {
            try await unpacker.unpack(file, into: staging)
            try Self.checkSymlinks(in: staging)
            let unpacked = ChromiumRuntimeInstallation(pin: pin, directory: staging)
            let items = try Self.requiredItems(of: unpacked)
            if let teamID = pin.teamID {
                // Read per item: a person's ensure(.user) during the checks raises the ones still to run.
                for item in items { try await signatures.check(item, teamID: teamID, priority: jobPriority ?? .background) }
            }
            Self.removeQuarantine(in: staging)
            let installation: ChromiumRuntimeInstallation
            do { installation = try store.activate(staging: staging, pin: pin) } catch {
                throw ChromiumRuntimeInstallError.filesystem(error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: file)
            return installation
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func progress(_ received: Int64, total: Int64) {
        guard case .downloading(let shown, _) = state, received > shown else { return }
        // At most one update per 0.5% (and the last byte).
        let step = max(1, total / 200)
        guard received / step != shown / step || received == total else { return }
        publish(.downloading(received: received, total: total))
    }

    private func publish(_ new: ChromiumRuntimeInstallState) {
        guard new != state else { return }
        state = new
        for listener in listeners.values { listener.yield(new) }
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    // MARK: - Checks (pure file work)

    static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// The lowercase hex sha256 of `file`, read in 1 MiB chunks.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle.blockingForReading(from: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.blockingRead(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Refuses absolute names, `..` components and anything outside the
    /// runtime folder (besides the pack's `cef-runtime.json`).
    static func checkEntries(_ names: [String], folder: String) throws(ChromiumRuntimeInstallError) {
        guard !names.isEmpty else { throw .missing(folder) }
        for raw in names {
            var name = raw
            while name.hasPrefix("./") { name.removeFirst(2) }
            if name.isEmpty || name == "." { continue }
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !components.contains(".."),
                  components.first.map(String.init) == folder || name == ChromiumRuntimePin.resourceName else {
                throw .unsafeEntry(raw)
            }
        }
    }

    /// Refuses a symlink whose target resolves outside `root`.
    static func checkSymlinks(in root: URL) throws(ChromiumRuntimeInstallError) {
        let rootPath = root.standardizedFileURL.path
        guard let relatives = try? FileManager.checked.subpathsOfDirectory(atPath: rootPath) else { throw .missing("pack") }
        for relative in relatives {
            let path = rootPath + "/" + relative
            guard let destination = try? FileManager.checked.destinationOfSymbolicLink(atPath: path) else { continue }
            let base = URL(filePath: path).deletingLastPathComponent()
            let resolved = destination.hasPrefix("/") ? URL(filePath: destination) : base.appending(path: destination)
            let target = resolved.standardizedFileURL.path
            guard target == rootPath || target.hasPrefix(rootPath + "/") else { throw .unsafeEntry(relative) }
        }
    }

    /// The framework, the shim and every helper app of an unpacked pack, or
    /// the first one missing.
    static func requiredItems(of installation: ChromiumRuntimeInstallation) throws(ChromiumRuntimeInstallError) -> [URL] {
        let frameworks = installation.frameworksDirectory
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        guard !entries.isEmpty else { throw .missing(installation.pin.folder) }
        guard entries.contains(ChromiumRuntimeLayoutNames.framework) else { throw .missing(ChromiumRuntimeLayoutNames.framework) }
        guard entries.contains(ChromiumRuntimeLayoutNames.shim) else { throw .missing(ChromiumRuntimeLayoutNames.shim) }
        let helpers = entries.filter { $0.hasSuffix(".app") && $0.contains(" Helper") }.sorted()
        guard helpers.contains(where: { $0.hasSuffix(" Helper.app") }) else { throw .missing("Helper.app") }
        return [ChromiumRuntimeLayoutNames.framework, ChromiumRuntimeLayoutNames.shim].map { frameworks.appending(path: $0) }
            + helpers.map { frameworks.appending(path: $0) }
    }

    /// Removes `com.apple.quarantine` from every item (the app downloaded
    /// the pack itself and verified it against its signed pin).
    static func removeQuarantine(in root: URL) {
        let rootPath = root.path
        removexattr(rootPath, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else { return }
        while let relative = enumerator.nextObject() as? String {
            removexattr(rootPath + "/" + relative, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }
}
