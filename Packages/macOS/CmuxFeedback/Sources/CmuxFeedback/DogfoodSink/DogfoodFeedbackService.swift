public import Foundation

/// Privileged agent feedback sink (the Mac to phone feedback loop).
///
/// Validates and persists a ``DogfoodFeedbackSubmission`` from a paired phone:
/// it caps each text field by character count *before* any large allocation,
/// rejects an oversized base64 blob without ever decoding it, decodes and
/// size-checks the blob, then writes a self-contained bundle directory under
/// `~/.cache/cmux-dogfood-feedback/<ISO8601>_<shortid>/` (a `bundle.json`
/// manifest plus the decoded `diagnostic.log`) and prunes old bundles.
///
/// The service is `nonisolated`: it holds no UI state, the cheap field caps run
/// on the caller's actor, and the decode plus synchronous filesystem I/O run on
/// a detached utility task so a multi-MiB payload can never stall the caller's
/// actor (the Mac UI). `FileManager`, the cache root, and the clock are injected
/// so tests can drive it against a temp directory with a fixed timestamp.
public struct DogfoodFeedbackService: Sendable {
    private let limits: DogfoodFeedbackLimits
    private let fileManagerProvider: @Sendable () -> FileManager
    private let cacheRoot: URL
    private let now: @Sendable () -> Date

    /// Create a feedback sink.
    ///
    /// `FileManager` is supplied through a provider closure rather than stored
    /// directly because `FileManager` is not `Sendable` and the writer runs on a
    /// detached task; the provider returns a fresh handle on the writer's
    /// executor.
    /// - Parameters:
    ///   - limits: the size and retention caps. Defaults to
    ///     ``DogfoodFeedbackLimits/default``.
    ///   - fileManagerProvider: returns the file manager used for all I/O.
    ///     Defaults to `FileManager.default`.
    ///   - cacheRoot: the directory bundles are written under. Defaults to
    ///     `~/.cache/cmux-dogfood-feedback`.
    ///   - now: the clock used to timestamp bundle names and manifests. Defaults
    ///     to the current date.
    public init(
        limits: DogfoodFeedbackLimits = .default,
        fileManagerProvider: @escaping @Sendable () -> FileManager = { .default },
        cacheRoot: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date.now }
    ) {
        self.limits = limits
        self.fileManagerProvider = fileManagerProvider
        self.cacheRoot = cacheRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("cmux-dogfood-feedback", isDirectory: true)
        self.now = now
    }

    /// The privileged feedback domain. Mirrors `isManaflowEmail` in
    /// `CmuxMobileShellModel` (the phone's routing source of truth) but is
    /// replicated here so the macOS app target need not link that mobile
    /// package just for this one suffix check. Trims and lowercases before
    /// matching so stored casing or padding does not bypass the gate.
    /// - Parameter email: the caller's authenticated account email, if any.
    /// - Returns: `true` when `email` is in the privileged `@manaflow.ai` domain.
    public static func isPrivilegedFeedbackEmail(_ email: String?) -> Bool {
        guard let email else { return false }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasSuffix("@manaflow.ai")
    }

    /// Validate and persist a feedback submission, returning the outcome to map
    /// onto an RPC response.
    ///
    /// The privilege check and the cheap per-field character caps run on the
    /// calling actor; an oversized base64 blob is rejected here without
    /// decoding. The decode plus filesystem writes run on a detached utility
    /// task so a large payload never blocks the caller.
    /// - Parameters:
    ///   - submission: the raw, un-capped wire fields.
    ///   - authenticatedEmail: the caller's authenticated account email, used to
    ///     enforce the privileged-domain gate at the trust boundary.
    /// - Returns: the ``DogfoodFeedbackOutcome`` describing success or the
    ///   precise failure.
    public func submit(
        _ submission: DogfoodFeedbackSubmission,
        authenticatedEmail: String?
    ) async -> DogfoodFeedbackOutcome {
        // Privilege check at the trust boundary: the privileged agent feedback
        // sink is restricted to the @manaflow.ai domain; a crafted request from
        // any other account is rejected here regardless of which route the phone
        // UI chose.
        guard Self.isPrivilegedFeedbackEmail(authenticatedEmail) else {
            return .unauthorized
        }

        // Cheap caller-actor validation first: cap each field by character count
        // before allocating anything large, and reject an oversized base64 blob
        // outright so it is never decoded into a giant Data.
        let text = String(submission.text.prefix(limits.maxTextChars))
        let terminalText = String(submission.terminalText.prefix(limits.maxTerminalChars))
        let buildStamp = String(submission.buildStamp.prefix(limits.maxBuildStampChars))
        let diagnosticBlobBase64 = submission.diagnosticBlobBase64
        guard diagnosticBlobBase64.count <= limits.maxBlobBase64Chars else {
            return .invalidParams(reason: "diagnostic_blob_base64 exceeds size limit")
        }

        let maxBlobBytes = limits.maxBlobBytes
        let fileManagerProvider = fileManagerProvider
        let cacheRoot = cacheRoot
        let maxRetainedBundles = limits.maxRetainedBundles
        let now = now
        // Off-caller-actor: decode the blob and write the bundle. A
        // `Task.detached` keeps the (potentially multi-MiB) decode plus
        // synchronous file I/O off the caller's actor so it never stalls the Mac
        // UI. Returns a Sendable outcome.
        return await Task.detached(priority: .utility) { () -> DogfoodFeedbackOutcome in
            let decoded = Data(base64Encoded: diagnosticBlobBase64) ?? Data()
            guard decoded.count <= maxBlobBytes else {
                return .invalidParams(reason: "diagnostic blob exceeds size limit")
            }
            return Self.writeBundle(
                text: text,
                terminalText: terminalText,
                buildStamp: buildStamp,
                diagnosticData: decoded,
                cacheRoot: cacheRoot,
                fileManager: fileManagerProvider(),
                maxRetainedBundles: maxRetainedBundles,
                now: now
            )
        }.value
    }

    /// Persist a validated feedback bundle to disk. Runs off the caller's actor
    /// (called from the detached task), so its synchronous file I/O never blocks
    /// the Mac UI. All text inputs are already size-capped by the caller.
    private static func writeBundle(
        text: String,
        terminalText: String,
        buildStamp: String,
        diagnosticData: Data,
        cacheRoot: URL,
        fileManager: FileManager,
        maxRetainedBundles: Int,
        now: @Sendable () -> Date
    ) -> DogfoodFeedbackOutcome {
        let root = cacheRoot

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Colons are legal in HFS+/APFS but awkward in shell globs; swap for `-`
        // so the directory name is paste-safe.
        let timestamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
        let shortID = String(UUID().uuidString.prefix(8)).lowercased()
        let bundleDir = root.appendingPathComponent("\(timestamp)_\(shortID)", isDirectory: true)

        do {
            // The bundle holds visible terminal text and debug logs, which can
            // contain credentials or other private data. Create the root and
            // bundle dirs owner-only (0700) so no other local user can traverse
            // into them, and chmod the written files to 0600. The dir is created
            // 0700 first, so even the brief window before the file chmod is not
            // world-readable through a traversable parent.
            let dirAttributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: dirAttributes
            )
            try fileManager.createDirectory(
                at: bundleDir,
                withIntermediateDirectories: true,
                attributes: dirAttributes
            )
            let diagnosticURL = bundleDir.appendingPathComponent("diagnostic.log")
            try diagnosticData.write(to: diagnosticURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnosticURL.path)
            let manifest: [String: Any] = [
                "schema": "cmux.dogfood.feedback.v1",
                "received_at": formatter.string(from: now()),
                "text": text,
                "terminal_text": terminalText,
                "build_stamp": buildStamp,
                "diagnostic_log_file": "diagnostic.log",
                "diagnostic_log_bytes": diagnosticData.count,
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
            let manifestURL = bundleDir.appendingPathComponent("bundle.json")
            try manifestData.write(to: manifestURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            return .internalError
        }

        pruneBundles(root: root, keep: maxRetainedBundles, fileManager: fileManager)
        return .written(bundlePath: bundleDir.path, diagnosticLogBytes: diagnosticData.count)
    }

    /// Keep only the newest `keep` bundle directories under `root`, deleting the
    /// rest. The directory names start with an ISO8601 timestamp, so a
    /// lexicographic sort is chronological. Best-effort: a failure to enumerate
    /// or remove is ignored (it only affects cleanup, not the just-written
    /// bundle). Runs off the caller's actor with its writer.
    private static func pruneBundles(root: URL, keep: Int, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let directories = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard directories.count > keep else { return }
        for stale in directories.dropLast(keep) {
            try? fileManager.removeItem(at: stale)
        }
    }
}
