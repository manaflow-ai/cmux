import CryptoKit
import Foundation

struct RemoteFilePreviewSource: Equatable, Sendable {
    let connection: SSHFileExplorerConnection
    let displayTarget: String
    let remotePath: String

    var displayPath: String {
        "ssh://\(displayTarget):\(remotePath)"
    }
}

enum RemoteFilePreviewMaterializerError: LocalizedError {
    case sshCommandFailed(status: Int32, detail: String)
    case launchFailed
    case materializationFailed

    var errorDescription: String? {
        switch self {
        case .sshCommandFailed, .materializationFailed:
            return String(localized: "filePreview.remote.error.downloadFailed", defaultValue: "Unable to download the remote file.")
        case .launchFailed:
            return String(localized: "filePreview.remote.error.sshLaunchFailed", defaultValue: "Unable to start SSH for remote preview.")
        }
    }

    static func logDiagnostic(_ message: String) {
#if DEBUG
        NSLog("[RemoteFilePreview] %@", message)
#else
        _ = message
#endif
    }
}

enum RemoteFilePreviewMaterializer {
    static func cacheURL(for source: RemoteFilePreviewSource) -> URL {
        let basename = sanitizedBasename(source.remotePath)
        let digest = SHA256.hash(data: Data(cacheKey(for: source).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-file-previews", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent(basename, isDirectory: false)
    }

    static func materialize(source: RemoteFilePreviewSource, to destinationURL: URL? = nil) async throws -> URL {
        let destinationURL = destinationURL ?? cacheURL(for: source)
        let operation = RemoteFilePreviewDownloadOperation(source: source, destinationURL: destinationURL)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try operation.run() })
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private static func cacheKey(for source: RemoteFilePreviewSource) -> String {
        [
            source.connection.destination,
            source.connection.port.map(String.init) ?? "",
            source.connection.identityFile ?? "",
            source.connection.sshOptions.joined(separator: "\u{1f}"),
            source.remotePath,
        ].joined(separator: "\u{1e}")
    }

    private static func sanitizedBasename(_ remotePath: String) -> String {
        let rawName = (remotePath as NSString).lastPathComponent
        let fallback = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "remote-file" : rawName
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.controlCharacters)
        let scalars = fallback.unicodeScalars.map { scalar in
            invalidCharacters.contains(scalar) ? "_" : String(scalar)
        }
        let name = scalars.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "remote-file" : name
    }
}

private final class RemoteFilePreviewDownloadOperation: @unchecked Sendable {
    private let source: RemoteFilePreviewSource
    private let destinationURL: URL
    private let process = Process()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var isCancelled = false

    init(source: RemoteFilePreviewSource, destinationURL: URL) {
        self.source = source
        self.destinationURL = destinationURL
    }

    func run() throws -> URL {
        lock.lock()
        let cancelledBeforeLaunch = isCancelled
        lock.unlock()
        if cancelledBeforeLaunch {
            throw CancellationError()
        }

        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).download-\(UUID().uuidString)", isDirectory: false)

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        } catch {
            RemoteFilePreviewMaterializerError.logDiagnostic("cache preparation failed: \(error.localizedDescription)")
            throw RemoteFilePreviewMaterializerError.materializationFailed
        }
        guard let outputHandle = try? FileHandle(forWritingTo: temporaryURL) else {
            RemoteFilePreviewMaterializerError.logDiagnostic("cache file handle creation failed")
            throw RemoteFilePreviewMaterializerError.materializationFailed
        }
        defer {
            try? outputHandle.close()
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(source: source)
        process.standardOutput = outputHandle
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            RemoteFilePreviewMaterializerError.logDiagnostic("ssh launch failed: \(error.localizedDescription)")
            throw RemoteFilePreviewMaterializerError.launchFailed
        }

        lock.lock()
        let cancelledAfterLaunch = isCancelled
        lock.unlock()
        if cancelledAfterLaunch {
            process.terminate()
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        lock.lock()
        let cancelledAfterExit = isCancelled
        lock.unlock()
        if cancelledAfterExit {
            try? fileManager.removeItem(at: temporaryURL)
            throw CancellationError()
        }

        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: temporaryURL)
            let detail = String(data: stderrData, encoding: .utf8) ?? ""
            RemoteFilePreviewMaterializerError.logDiagnostic("ssh exited with status \(process.terminationStatus): \(detail)")
            throw RemoteFilePreviewMaterializerError.sshCommandFailed(status: process.terminationStatus, detail: detail)
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            RemoteFilePreviewMaterializerError.logDiagnostic("cache commit failed: \(error.localizedDescription)")
            throw RemoteFilePreviewMaterializerError.materializationFailed
        }
        return destinationURL
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    private func sshArguments(source: RemoteFilePreviewSource) -> [String] {
        var args: [String] = []
        if let port = source.connection.port {
            args += ["-p", String(port)]
        }
        if let identityFile = source.connection.identityFile {
            args += ["-i", identityFile]
        }
        for option in source.connection.sshOptions {
            args += ["-o", option]
        }
        args += [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-T",
            source.connection.destination,
            "cat < \(shellSingleQuoted(source.remotePath))",
        ]
        return args
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
