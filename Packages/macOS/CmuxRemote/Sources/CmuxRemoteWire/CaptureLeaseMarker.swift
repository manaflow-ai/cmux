public import Foundation
import Darwin

/// Durable ownership, shared by the host and its identity writer. A failed cleanup keeps it.
public struct CaptureLeaseMarker: Codable, Equatable, Sendable {
    public let binding: CaptureLeaseBinding
    public let keychainScope: String
    public var workerStarted: Bool
    public var cleaning: Bool

    public init(binding: CaptureLeaseBinding, keychainScope: String) {
        self.binding = binding; self.keychainScope = keychainScope
        workerStarted = false; cleaning = false
    }

    public static func path(stateDirectory: String) -> String { stateDirectory + "/capture-lease.json" }

    public static func read(stateDirectory: String) throws -> Self? {
        let descriptor = open(path(stateDirectory: stateDirectory), O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= 16_384 else { throw CocoaError(.fileReadNoPermission) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw CocoaError(.fileReadUnknown) }
        return try JSONDecoder().decode(Self.self, from: Data(bytes))
    }

    /// Cross-process compare-and-set for the host and worker. Never waits for another process.
    /// This file lock protects only bounded marker I/O off MainActor, not an async operation.
    public static func transaction<T>(stateDirectory: String, _ update: (inout Self?) throws -> T) throws -> T {
        let descriptor = open(stateDirectory + "/capture-lease.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o077) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { flock(descriptor, LOCK_UN) }
        var marker = try read(stateDirectory: stateDirectory)
        let original = marker
        let result = try update(&marker)
        if marker != original {
            guard let marker else { throw CocoaError(.fileWriteNoPermission) }
            try marker.write(stateDirectory: stateDirectory)
        }
        return result
    }

    /// Atomic same-directory replacement; the directory is the host's validated private state.
    private func write(stateDirectory: String) throws {
        let target = Self.path(stateDirectory: stateDirectory)
        let temporary = stateDirectory + "/.capture-lease-" + UUID().uuidString
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor); unlink(temporary) }
        let data = try JSONEncoder().encode(self)
        guard LineChannel.writeAll(descriptor, data), fsync(descriptor) == 0,
              rename(temporary, target) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directory = open(stateDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The worker records ownership before any identity or relay write. A cleaning marker is terminal.
    public static func authorizeIdentity(stateDirectory: String, keychainScope: String, home: String) throws {
        // Ordinary launches do not create capture state or take a capture lock.
        guard try read(stateDirectory: stateDirectory) != nil else { return }
        try transaction(stateDirectory: stateDirectory) { stored in
            guard var marker = stored else { throw CocoaError(.fileWriteNoPermission) }
            guard !marker.cleaning, marker.keychainScope == keychainScope,
                  marker.binding.owns(stateDirectory: stateDirectory, home: home) else { throw CocoaError(.fileWriteNoPermission) }
            marker.workerStarted = true
            stored = marker
        }
    }
}
