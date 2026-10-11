public import Foundation

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
    }

    /// Larger than any real export; a bigger file is not a password CSV.
    static let maximumSize = 64 << 20

    let destination: any PasswordDestination

    public init(destination: any PasswordDestination) {
        self.destination = destination
    }

    public func run(file: URL, intoProfile profileID: String) async throws -> PasswordImportReport {
        guard destination.isAvailable else { throw Failure.storeUnavailable }
        // File IO off the caller's actor; the plaintext never leaves this task.
        let read = try await Task.detached { try Self.parse(Self.read(file)) }.value
        return try await store(read, intoProfile: profileID)
    }

    /// The whole file, read into its own locked buffer.
    static func read(_ file: URL) throws(Failure) -> SecretBytes {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw .unreadable }
        let size = Int(info.st_size)
        guard size <= maximumSize else { throw .unreadable }
        var failed = false
        let bytes = SecretBytes(capacity: size) { out in
            guard let base = out.baseAddress else { return 0 }  // an empty buffer reads nothing
            var done = 0
            // Each read returns at least one byte until the end, so this ends within size + 1 steps.
            for _ in 0...size where done < size && !failed {
                let count = Darwin.read(descriptor, base + done, size - done) // concurrency-allow: called only from Task.detached in run(file:intoProfile:)
                if count > 0 { done += count } else if count == 0 || errno != EINTR { failed = count < 0; break }
            }
            return done
        }
        if failed { throw .unreadable }
        return bytes
    }

    static func parse(_ bytes: SecretBytes) throws(Failure) -> (logins: [ImportedLogin], skipped: LoginSkipCounts) {
        do {
            return try bytes.withUnsafeBytes { try PasswordCSVReader().read($0) }
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
