import Foundation

/// Thread-safe collector for session index scan errors.
/// Safety: all mutable state is guarded by `lock`, so instances can cross tasks.
public nonisolated final class SessionIndexErrorBag: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    public init() {}

    public func add(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

public enum SessionIndexCore {
    public nonisolated static let headByteCap = 64 * 1024
    public nonisolated static let tailByteCap = 32 * 1024
    /// Hard cap on candidate files inspected per call to keep deep-page searches bounded.
    public nonisolated static let searchMaxFiles = 1500
    // CMUXAgentVault targets macOS 13+, so `FileHandle.read(upToCount:)` does not need an older 10.15.4 fallback.

    /// Stream JSON-lines from the start of `url`. `body` returns true to stop early.
    /// Caps total bytes read at `maxBytes`.
    public nonisolated static func forEachJSONLine(
        url: URL,
        maxBytes: Int,
        body: ([String: Any]) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var leftover = Data()
        var totalRead = 0
        let chunkSize = 64 * 1024
        while totalRead < maxBytes {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            totalRead += chunk.count
            leftover.append(chunk)
            while let newlineIndex = leftover.firstIndex(of: 0x0a) {
                let lineData = leftover.subdata(in: 0..<newlineIndex)
                leftover.removeSubrange(0..<(newlineIndex + 1))
                if lineData.isEmpty { continue }
                if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   body(object) {
                    return
                }
            }
        }

        if !leftover.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: leftover) as? [String: Any] {
            _ = body(object)
        }
    }

    /// Read up to `byteCap` bytes from the start of the file as UTF-8.
    public nonisolated static func readFileHead(url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// Read up to `byteCap` bytes from the end of the file as UTF-8.
    /// Used to find late-arriving events like pr-link without scanning the whole file.
    public nonisolated static func readFileTail(url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return ""
        }
        if size == 0 { return "" }

        let cap = UInt64(byteCap)
        let offset = size > cap ? size - cap : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ""
        }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        // Trim leading partial line when the read starts mid-record.
        if offset > 0, let newlineIndex = data.firstIndex(of: 0x0a) {
            return String(data: data[(newlineIndex + 1)...], encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Return true when `needle` appears in `url`, scanning in chunks with overlap.
    public nonisolated static func fileContainsNeedle(url: URL, needle: String) -> Bool {
        guard !needle.isEmpty,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let overlapLimit = max(needle.utf8.count * 4, 4 * 1024)
        var carry = Data()
        while !Task.isCancelled {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }

            var buffer = carry
            buffer.append(chunk)
            let text = String(decoding: buffer, as: UTF8.self)
            if text.range(of: needle, options: [.caseInsensitive, .literal]) != nil {
                return true
            }
            carry = buffer.count > overlapLimit ? Data(buffer.suffix(overlapLimit)) : buffer
        }
        return false
    }

    /// Run `rg --files-with-matches --ignore-case --fixed-strings` for `needle`
    /// under `root`, restricted to `fileGlob` (for example, `*.jsonl`). Returns
    /// matched file URLs, or nil if rg is unavailable or failed so callers can
    /// fall back to Foundation scanning.
    @concurrent
    public static func ripgrepMatchingPaths(
        needle: String,
        root: String,
        fileGlob: String
    ) async -> [URL]? {
        guard let rg = cachedRipgrepPath else { return nil }
        let processBox = CancellableProcessBox()

        return await withTaskCancellationHandler {
            let process = Process()
            processBox.set(process)
            process.executableURL = URL(fileURLWithPath: rg)
            process.arguments = [
                "--files-with-matches",
                "--ignore-case",
                "--fixed-strings",
                "--no-messages",
                "--no-ignore",
                "--hidden",
                "--glob", fileGlob,
                "--",
                needle,
                root,
            ]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil as [URL]?
            }

            // Drain stdout before waiting; otherwise rg can fill the pipe buffer and deadlock before exit.
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            processBox.clear(process)

            switch process.terminationStatus {
            case 0:
                guard let output = String(data: data, encoding: .utf8) else {
                    return nil as [URL]?
                }
                return output.split(separator: "\n", omittingEmptySubsequences: true)
                    .map { URL(fileURLWithPath: String($0)) }
            case 1:
                return []
            default:
                return nil
            }
        } onCancel: {
            processBox.terminate()
        }
    }

    private nonisolated static let cachedRipgrepPath: String? = {
        let fileManager = FileManager.default
        let commonPaths = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
            "/opt/local/bin/rg",
        ]
        for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for directory in pathEnv.split(separator: ":") {
                let fullPath = String(directory) + "/rg"
                if fileManager.isExecutableFile(atPath: fullPath) {
                    return fullPath
                }
            }
        }
        return nil
    }()
}

// Safety: all access to `process` is guarded by `lock`; terminate snapshots under the same lock.
private nonisolated final class CancellableProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    func clear(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process {
            self.process = nil
        }
    }

    func terminate() {
        lock.lock()
        let process = process
        lock.unlock()
        process?.terminate()
    }
}
