import Darwin
import Foundation

enum AppHostProcessReceipt {
    static func writeIfRequired() {
        _ = retainedReceiptDescriptor
        _ = retainedLeaseDescriptor
    }

    /// The open descriptor is the process-incarnation proof. Keeping it alive
    /// until process exit prevents a reused PID at the same executable path
    /// from inheriting authority from a durable receipt.
    private static let retainedAuthority = createIfRequired()
    private static let retainedReceiptDescriptor = retainedAuthority.receipt
    private static let retainedLeaseDescriptor = retainedAuthority.lease

    private static func createIfRequired() -> (receipt: Int32, lease: Int32) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1" else {
            return (-1, -1)
        }
        guard
            let receiptDirectory = environment["CMUX_APP_HOST_RECEIPT_DIR"],
            !receiptDirectory.isEmpty,
            !receiptDirectory.contains(where: { $0.isNewline }),
            let leasePath = environment["CMUX_APP_HOST_ATTEMPT_LEASE"],
            !leasePath.isEmpty,
            !leasePath.contains(where: { $0.isNewline }),
            let key = environment["CMUX_APP_HOST_KEY"],
            key.utf8.count == 12,
            key.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
            let executablePath = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
            !executablePath.contains(where: { $0.isNewline })
        else {
            fail("required identity is incomplete")
        }

        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: receiptDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            fail("receipt directory is unavailable")
        }
        do {
            let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  directoryURL.standardizedFileURL.path == directoryURL.resolvingSymlinksInPath().path
            else {
                fail("receipt directory changed identity")
            }

            let leaseURL = URL(fileURLWithPath: leasePath, isDirectory: false)
            guard leaseURL.deletingLastPathComponent().standardizedFileURL.path == directoryURL.standardizedFileURL.path,
                  leaseURL.lastPathComponent.hasPrefix("app-host-attempt-"),
                  leaseURL.lastPathComponent.hasSuffix(".lease")
            else {
                fail("attempt lease is outside the receipt directory")
            }
            let leaseDescriptor = leaseURL.path.withCString {
                Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            }
            guard leaseDescriptor >= 0 else {
                fail("attempt lease could not be opened safely")
            }
            var leaseMetadata = stat()
            guard Darwin.fstat(leaseDescriptor, &leaseMetadata) == 0,
                  (leaseMetadata.st_mode & S_IFMT) == S_IFREG,
                  (leaseMetadata.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
                  leaseMetadata.st_uid == getuid()
            else {
                Darwin.close(leaseDescriptor)
                fail("attempt lease identity is invalid")
            }
            if setAttemptLeaseLock(leaseDescriptor, blocking: false) == 0 {
                Darwin.close(leaseDescriptor)
                fail("attempt lease has no live holder")
            }
            guard errno == EACCES || errno == EAGAIN else {
                Darwin.close(leaseDescriptor)
                fail("attempt lease state could not be verified")
            }
            let pid = getpid()
            let receiptURL = directoryURL.appendingPathComponent("app-host-\(pid).receipt", isDirectory: false)
            var descriptor: Int32 = -1
            var temporaryURL: URL?
            for _ in 0 ..< 8 {
                let candidateURL = directoryURL.appendingPathComponent(
                    ".app-host-\(pid)-\(UUID().uuidString.lowercased()).receipt.tmp",
                    isDirectory: false
                )
                descriptor = candidateURL.path.withCString {
                    Darwin.open(
                        $0,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
                if descriptor >= 0 {
                    temporaryURL = candidateURL
                    break
                }
                guard errno == EEXIST else {
                    fail("temporary receipt file could not be opened safely")
                }
            }
            guard descriptor >= 0, let temporaryURL else {
                fail("a unique temporary receipt file could not be created")
            }
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                discardTemporaryReceipt(descriptor, at: temporaryURL)
                fail("receipt permissions could not be restricted")
            }
            let receipt = "version=3\nkey=\(key)\npid=\(pid)\nexecutable=\(executablePath)\nreceipt_fd=\(descriptor)\nlease=\(leasePath)\nlease_fd=\(leaseDescriptor)\n"
            let receiptData = Data(receipt.utf8)
            let wroteReceipt = receiptData.withUnsafeBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return true }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            guard wroteReceipt, Darwin.fsync(descriptor) == 0 else {
                discardTemporaryReceipt(descriptor, at: temporaryURL)
                fail("receipt contents could not be persisted")
            }
            let published = temporaryURL.path.withCString { temporaryPath in
                receiptURL.path.withCString { receiptPath in
                    Darwin.rename(temporaryPath, receiptPath) == 0
                }
            }
            guard published else {
                discardTemporaryReceipt(descriptor, at: temporaryURL)
                fail("receipt file could not be published atomically")
            }
            watchAttemptLease(leaseDescriptor)
            return (descriptor, leaseDescriptor)
        } catch {
            fail(error.localizedDescription)
        }
    }

    nonisolated private static func setAttemptLeaseLock(_ descriptor: Int32, blocking: Bool) -> Int32 {
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, blocking ? F_SETLKW : F_SETLK, &lock)
    }

    nonisolated private static func watchAttemptLease(_ descriptor: Int32) {
        Thread.detachNewThread {
            while setAttemptLeaseLock(descriptor, blocking: true) != 0 {
                if errno == EINTR {
                    continue
                }
                fputs("FAIL: app-host attempt lease watcher failed\n", stderr)
                fflush(stderr)
                Darwin._exit(70)
            }
            Darwin._exit(0)
        }
    }

    private static func discardTemporaryReceipt(_ descriptor: Int32, at url: URL) {
        let savedErrno = errno
        Darwin.close(descriptor)
        url.path.withCString { _ = Darwin.unlink($0) }
        errno = savedErrno
    }

    private static func fail(_ reason: String) -> Never {
        fputs("FAIL: app-host process receipt: \(reason)\n", stderr)
        fflush(stderr)
        Darwin.exit(70)
    }
}
