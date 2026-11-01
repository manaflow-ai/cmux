import CryptoKit
import Darwin
import Foundation

struct NativeDeviceRecord: Codable, Sendable {
    var privateKey: String
    var device: String?
    var key: Curve25519.KeyAgreement.PrivateKey { get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: privateKey) ?? Data()) } }
}

/// Device enrollment must keep one identity per account, team and mesh.
struct NativeDeviceStore: Sendable {
    let root: URL
    let namespace: String
    var secret: (any NativeDeviceSecret)? = nil
    private var directory: URL {
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("native-meshes", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
    }
    var file: URL { directory.appendingPathComponent("identity.json") }

    func lock() throws -> NativeDeviceLock {
        try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try NativeDeviceLock(file: directory.appendingPathComponent("identity.lock"))
    }

    func loadOrCreate(create: Bool = true) throws -> NativeDeviceRecord {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT, create else { throw NativeDeviceEnrollmentError.invalidState }
            let bytes = try secret?.load(namespace: namespace, create: true) ?? Curve25519.KeyAgreement.PrivateKey().rawRepresentation
            guard bytes.count == 32 else { throw NativeDeviceEnrollmentError.invalidState }
            let record = NativeDeviceRecord(privateKey: bytes.base64EncodedString())
            try save(record)
            return record
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16_384 else { throw NativeDeviceEnrollmentError.invalidState }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16_385) ?? Data()
        guard data.count == Int(info.st_size) else { throw NativeDeviceEnrollmentError.invalidState }
        if let secret {
            guard let checkpoint = try? JSONDecoder().decode(NativeDeviceCheckpoint.self, from: data), checkpoint.secure,
                  checkpoint.device.map(NativeDeviceScope.isDevice) ?? true else { throw NativeDeviceEnrollmentError.invalidState }
            let bytes = try secret.load(namespace: namespace, create: false)
            guard bytes.count == 32 else { throw NativeDeviceEnrollmentError.invalidState }
            return NativeDeviceRecord(privateKey: bytes.base64EncodedString(), device: checkpoint.device)
        }
        guard let record = try? JSONDecoder().decode(NativeDeviceRecord.self, from: data),
              (try? record.key) != nil, record.device.map(NativeDeviceScope.isDevice) ?? true else { throw NativeDeviceEnrollmentError.invalidState }
        return record
    }

    func save(_ record: NativeDeviceRecord) throws {
        let data = try secret == nil ? JSONEncoder().encode(record) : JSONEncoder().encode(NativeDeviceCheckpoint(device: record.device, secure: true))
        try OwnerOnlyFile.write(data, to: file)
    }
}

private struct NativeDeviceCheckpoint: Codable { let device: String?; let secure: Bool }

/// Non-blocking across processes; explicit unlock also releases a fork-inherited lock.
final class NativeDeviceLock {
    private let fd: Int32
    init(file: URL) throws {
        fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeDeviceEnrollmentError.invalidState }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw NativeDeviceEnrollmentError.invalidState
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw NativeDeviceEnrollmentError.busy }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
