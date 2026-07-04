@preconcurrency import CoreML
import FluidAudio
public import Foundation

/// Downloads Parakeet v3 through FluidAudio.
public struct FluidAudioParakeetModelDownloader: ParakeetModelDownloading {
    private static let repositoryTreeURL = URL(
        string: "https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/main?recursive=true"
    )!
    private static let repositoryResolveBaseURL = URL(
        string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/"
    )!
    private static let maxDownloadAttempts = 3
    private static let streamBufferSize = 64 * 1024

    /// Creates the real FluidAudio-backed downloader.
    public init() {}

    /// Download the Parakeet v3 int8 model and compile it for CoreML.
    /// - Parameters:
    ///   - directory: The custom model directory root.
    ///   - progress: Receives mapped progress snapshots.
    public func download(
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        progress(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: "listing"))
        let files = try await listRequiredFiles(session: session)
        try await download(files: files, to: directory, session: session, progress: progress)

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        _ = try await AsrModels.downloadAndLoad(
            to: directory,
            configuration: configuration,
            version: .v3,
            encoderPrecision: .int8,
            encoderComputeUnits: nil,
            progressHandler: { fluidProgress in
                progress(Self.progress(from: fluidProgress))
            }
        )
    }

    /// Returns whether the FluidAudio-required v3 int8 model files exist.
    /// - Parameter directory: The custom model directory root.
    /// - Returns: `true` when the model is installed.
    public static func modelsExist(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8)
    }

    static func progress(from progress: DownloadUtils.DownloadProgress) -> ParakeetDownloadProgress {
        // FluidAudio maps the byte download to fractionCompleted 0.0-0.5 and the
        // CoreML compile to 0.5-1.0 (DownloadUtils.downloadRepo). Rendering that
        // raw makes a 483 MB download crawl to "50%" and then jump, so remap the
        // download phase to the full 0...1 range and let the UI treat listing and
        // compiling as indeterminate phases.
        switch progress.phase {
        case .listing:
            return ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: "listing")
        case .downloading:
            return ParakeetDownloadProgress(
                fractionCompleted: min(progress.fractionCompleted / 0.5, 1),
                phaseDescription: "downloading"
            )
        case .compiling:
            return ParakeetDownloadProgress(fractionCompleted: 1, phaseDescription: "compiling")
        }
    }

    private func listRequiredFiles(session: URLSession) async throws -> [ParakeetModelDownloadFile] {
        let (data, response) = try await session.data(from: Self.repositoryTreeURL)
        try Self.validateHTTPResponse(response, path: "repository tree")
        return try ParakeetModelDownloadFile.files(fromHuggingFaceTreeJSON: data)
    }

    private func download(
        files: [ParakeetModelDownloadFile],
        to directory: URL,
        session: URLSession,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let totalBytes = ParakeetModelDownloadFile.totalBytes(in: files)
        var downloadedBytes: Int64 = 0
        var throttler = ParakeetDownloadProgressThrottler(totalBytes: totalBytes)
        progress(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: "downloading"))

        for file in files {
            try Task.checkCancellation()
            if let existingBytes = try file.existingCompleteByteCount(in: directory) {
                downloadedBytes += existingBytes
                if let update = throttler.progressIfNeeded(downloadedBytes: downloadedBytes) {
                    progress(update)
                }
                continue
            }

            let destination = file.destination(in: directory)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try await downloadFileWithRetry(
                file,
                to: destination,
                session: session,
                downloadedBytes: &downloadedBytes,
                throttler: &throttler,
                progress: progress
            )
        }

        if let update = throttler.progressIfNeeded(downloadedBytes: totalBytes) {
            progress(update)
        }
    }

    private func downloadFileWithRetry(
        _ file: ParakeetModelDownloadFile,
        to destination: URL,
        session: URLSession,
        downloadedBytes: inout Int64,
        throttler: inout ParakeetDownloadProgressThrottler,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        var lastError: (any Error)?
        for attempt in 1...Self.maxDownloadAttempts {
            do {
                try await downloadFile(
                    file,
                    to: destination,
                    session: session,
                    downloadedBytes: &downloadedBytes,
                    throttler: &throttler,
                    progress: progress
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                guard attempt < Self.maxDownloadAttempts, Self.isTransient(error) else {
                    throw error
                }
            }
        }
        if let lastError { throw lastError }
    }

    private func downloadFile(
        _ file: ParakeetModelDownloadFile,
        to destination: URL,
        session: URLSession,
        downloadedBytes: inout Int64,
        throttler: inout ParakeetDownloadProgressThrottler,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).download")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        var didFinish = false
        defer {
            if !didFinish {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        let url = Self.resolveURL(for: file.path)
        let (bytes, response) = try await session.bytes(from: url)
        try Self.validateHTTPResponse(response, path: file.path)

        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var fileBytesWritten: Int64 = 0
        var buffer = [UInt8]()
        buffer.reserveCapacity(Self.streamBufferSize)

        func flushBuffer() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: Data(buffer))
            fileBytesWritten += Int64(buffer.count)
            let currentBytes = downloadedBytes + fileBytesWritten
            if let update = throttler.progressIfNeeded(downloadedBytes: currentBytes) {
                progress(update)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.streamBufferSize {
                // Cancellation is checked once per 64 KB flush, not per byte:
                // the per-byte check executes ~500M times over a full download
                // and costs measurable CPU on-device.
                try Task.checkCancellation()
                try flushBuffer()
            }
        }
        try Task.checkCancellation()
        try flushBuffer()

        guard fileBytesWritten == file.size else {
            throw ParakeetDownloadError.sizeMismatch(
                path: file.path,
                expected: file.size,
                actual: fileBytesWritten
            )
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        downloadedBytes += fileBytesWritten
        didFinish = true
    }

    private static func resolveURL(for path: String) -> URL {
        path.split(separator: "/", omittingEmptySubsequences: true).reduce(Self.repositoryResolveBaseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private static func validateHTTPResponse(_ response: URLResponse, path: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParakeetDownloadError.invalidResponse(path: path)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ParakeetDownloadError.httpStatus(path: path, statusCode: httpResponse.statusCode)
        }
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if let error = error as? ParakeetDownloadError {
            return error.isTransient
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }
}
