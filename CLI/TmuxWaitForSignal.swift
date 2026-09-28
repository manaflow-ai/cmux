import Darwin
import Foundation

/// The marker file behind `cmux wait-for`: `-S` creates it and a waiter
/// consumes it, so a signal sent before the wait still wakes the waiter.
struct TmuxWaitForSignal {
    let path: String

    init(name: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitized = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        path = "/tmp/cmux-wait-for-\(String(sanitized)).sig"
    }

    func signal() throws {
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    /// Returns true once the signal has arrived and been consumed, false on timeout.
    func wait(timeout: TimeInterval) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try Self.waitForFilesystemPath(path, timeout: max(0, deadline.timeIntervalSinceNow))
            try? FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                return true
            }
        }
        return false
    }

    private static func waitForFilesystemPath(_ path: String, timeout: TimeInterval) throws {
        if FileManager.default.fileExists(atPath: path) {
            return
        }

        guard let watchDirectory = existingWatchDirectory(forPath: path) else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }
        let watchFD = open(watchDirectory, O_EVTONLY)
        guard watchFD >= 0 else {
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        let queue = DispatchQueue(label: "com.cmux.cli.path-watch.\(UUID().uuidString)")
        let semaphore = DispatchSemaphore(value: 0)
        var found = false
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .link],
            queue: queue
        )

        func checkPath() {
            guard !found else { return }
            if FileManager.default.fileExists(atPath: path) {
                found = true
                semaphore.signal()
            }
        }

        source.setEventHandler {
            checkPath()
        }
        source.setCancelHandler {
            Darwin.close(watchFD)
        }
        source.resume()
        queue.async {
            checkPath()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            source.cancel()
            throw CLIError(message: "Timed out waiting for \(path)")
        }

        source.cancel()
    }

    private static func existingWatchDirectory(forPath path: String) -> String? {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)

        while !candidate.path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return nil
    }
}
