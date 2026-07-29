import Darwin
import Foundation
import Testing

final class ProcessMarkerFixture {
    let readyFIFOURL: URL
    let exitFIFOURL: URL
    let markerURL: URL

    init() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        readyFIFOURL = temporaryDirectory.appendingPathComponent(
            "cmux-remote-process-\(identifier).ready",
            isDirectory: false
        )
        exitFIFOURL = temporaryDirectory.appendingPathComponent(
            "cmux-remote-process-\(identifier).exit",
            isDirectory: false
        )
        markerURL = temporaryDirectory.appendingPathComponent(
            "cmux-remote-process-\(identifier).pid",
            isDirectory: false
        )

        guard Darwin.mkfifo(readyFIFOURL.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.mkfifo(exitFIFOURL.path, 0o600) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: readyFIFOURL)
            throw POSIXError(code)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: readyFIFOURL)
        try? FileManager.default.removeItem(at: exitFIFOURL)
        try? FileManager.default.removeItem(at: markerURL)
    }

    func recordedProcessHasExited() throws -> Bool {
        let contents = try String(contentsOf: markerURL, encoding: .utf8)
        let processIdentifier = try #require(
            pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        errno = 0
        return Darwin.kill(processIdentifier, 0) == -1 && errno == ESRCH
    }
}
