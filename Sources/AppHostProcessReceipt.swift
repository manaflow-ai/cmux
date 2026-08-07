import Darwin
import Foundation

enum AppHostProcessReceipt {
    static func writeIfRequired() {
        _ = retainedReceiptDescriptor
    }

    /// The open descriptor is the process-incarnation proof. Keeping it alive
    /// until process exit prevents a reused PID at the same executable path
    /// from inheriting authority from a durable receipt.
    private static let retainedReceiptDescriptor: Int32 = createIfRequired()

    private static func createIfRequired() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1" else { return -1 }
        guard
            let receiptDirectory = environment["CMUX_APP_HOST_RECEIPT_DIR"],
            !receiptDirectory.isEmpty,
            !receiptDirectory.contains(where: { $0.isNewline }),
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

            let pid = getpid()
            let receiptURL = directoryURL.appendingPathComponent("app-host-\(pid).receipt", isDirectory: false)
            let descriptor = receiptURL.path.withCString {
                Darwin.open(
                    $0,
                    O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard descriptor >= 0 else {
                fail("receipt file could not be opened safely")
            }
            guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                Darwin.close(descriptor)
                fail("receipt permissions could not be restricted")
            }
            let receipt = "version=2\nkey=\(key)\npid=\(pid)\nexecutable=\(executablePath)\nreceipt_fd=\(descriptor)\n"
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
                Darwin.close(descriptor)
                fail("receipt contents could not be persisted")
            }
            return descriptor
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ reason: String) -> Never {
        fputs("FAIL: app-host process receipt: \(reason)\n", stderr)
        fflush(stderr)
        Darwin.exit(70)
    }
}
