public import Foundation
import CmuxNextCompat

/// Imports a password CSV the user chose into one cmux browser profile's
/// Chromium password store, through the same destination as the browser
/// import. The file is read straight into `SecretBytes` (no `Data`, no
/// mapping, so the only copy of its plaintext is zeroed when the read ends),
/// parsed in place, and nothing is written anywhere but the store; the
/// result is counts only.
public struct PasswordCSVImporter: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case storeUnavailable
        case unreadable
        case noPasswordColumns
        /// The person closed the column sheet.
        case cancelled
    }

    /// Larger than any real export; a bigger file is not a password CSV.
    static let maximumSize = 64 << 20

    let destination: any PasswordDestination

    public init(destination: any PasswordDestination) {
        self.destination = destination
    }

    /// `columns` is asked, only when the header names no website or password column, to match
    /// them by the header's names (the column sheet); nil keeps such a file a failure.
    public func run(file: URL, intoProfile profileID: String,
                    columns: (@MainActor @Sendable (PasswordCSVHeader) async -> PasswordCSVColumns?)? = nil) async throws -> PasswordImportReport {
        guard destination.isAvailable else { throw Failure.storeUnavailable }
        // File IO and parsing off the caller's actor; the plaintext stays in the locked buffer.
        let bytes = try await Task.detached { try Self.read(file) }.value
        let read: (logins: [ImportedLogin], skipped: LoginSkipCounts)
        do {
            read = try await Task.detached { try Self.parse(bytes) }.value
        } catch Failure.noPasswordColumns {
            guard let columns, let header = PasswordCSVHeader.read(bytes) else { throw Failure.noPasswordColumns }
            guard let match = await columns(header) else { throw Failure.cancelled }
            read = try await Task.detached { try Self.parse(bytes, columns: match) }.value
        }
        return try await store(read, intoProfile: profileID)
    }

    /// The whole file, read into its own locked buffer.
    static func read(_ file: URL) throws(Failure) -> SecretBytes {
        try read(file, limit: maximumSize)
    }

    /// The whole file when it is at most `limit` bytes (an export archive's limit is larger).
    static func read(_ file: URL, limit: Int) throws(Failure) -> SecretBytes {
        // SAFETY: the path is a NUL-terminated copy Swift keeps alive for the call; open only reads it.
        let descriptor = unsafe blockingOpen(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadable }
        defer { close(descriptor) }
        var info = stat()
        // SAFETY: fstat writes one `stat` into the local `info`, which outlives the call.
        guard unsafe fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable }
        guard let size = Int(exactly: info.st_size), (0...limit).contains(size) else { throw .unreadable }
        var failed = false
        let bytes = SecretBytes(capacity: size) { out in
            // SAFETY: reads the base address of the buffer SecretBytes lends for this closure.
            guard let base = unsafe out.baseAddress else { return 0 }  // an empty buffer reads nothing
            var done = 0
            // Each read returns at least one byte until the end, so this ends within size + 1 steps.
            for _ in 0...size where done < size && !failed {
                // SAFETY: `out` holds max(size, 1) bytes (the capacity asked for) and 0 <= done < size,
                // so read writes at most size - done bytes from base + done, inside the buffer.
                let count = unsafe blockingRead(descriptor, base + done, size - done) // concurrency-allow: called only from Task.detached (run(file:intoProfile:), BrowserFileImport)
                if count > 0 { done += count } else if count == 0 || errno != EINTR { failed = count < 0; break }
            }
            return done
        }
        if failed { throw .unreadable }
        return bytes
    }

    /// Imports a CSV already in memory (an export archive's Passwords.csv).
    public func run(bytes: SecretBytes, intoProfile profileID: String) async throws -> PasswordImportReport {
        guard destination.isAvailable else { throw Failure.storeUnavailable }
        let read = try Self.parse(bytes)
        return try await store(read, intoProfile: profileID)
    }

    static func parse(_ bytes: SecretBytes, columns: PasswordCSVColumns? = nil) throws(Failure) -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        do {
            return try PasswordCSVReader().read(bytes, columns: columns)
        } catch {
            throw .noPasswordColumns
        }
    }

    func store(_ read: (logins: [ImportedLogin], skipped: LoginSkipCounts), intoProfile profileID: String) async throws -> PasswordImportReport {
        var report = PasswordImportReport()
        report.read = read.logins.count + read.skipped.total
        report.skipped = read.skipped
        if !read.logins.isEmpty { report.store = try await destination.add(read.logins, toProfile: profileID) }
        return report
    }
}
