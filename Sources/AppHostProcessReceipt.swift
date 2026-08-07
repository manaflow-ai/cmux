import Darwin
import Foundation

enum AppHostProcessReceipt {
    static func writeIfRequired() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1" else { return }
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
            let receipt = "version=1\nkey=\(key)\npid=\(pid)\nexecutable=\(executablePath)\n"
            let receiptURL = directoryURL.appendingPathComponent("app-host-\(pid).receipt", isDirectory: false)
            try Data(receipt.utf8).write(to: receiptURL, options: .atomic)
            let permissionStatus = receiptURL.path.withCString {
                Darwin.chmod($0, mode_t(S_IRUSR | S_IWUSR))
            }
            guard permissionStatus == 0 else {
                fail("receipt permissions could not be restricted")
            }
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
