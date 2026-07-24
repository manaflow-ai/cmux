@preconcurrency import CoreML
import FluidAudio
public import Foundation

/// Downloads Parakeet CoreML assets with byte-level progress.
public struct FluidAudioParakeetModelDownloader: ParakeetModelDownloading, ParakeetVocabularyBoostDownloading {
    private static let maxDownloadAttempts = 3
    private static let streamBufferSize = 64 * 1024

    /// Creates the real FluidAudio-backed downloader.
    public init() {}

    /// Download the Parakeet v3 int8 model and compile it for CoreML.
    /// - Parameters:
    ///   - descriptor: Model catalog entry to download.
    ///   - directory: The custom model directory root.
    ///   - progress: Receives mapped progress snapshots.
    public func download(
        _ descriptor: ParakeetModelDescriptor = .parakeetV3Int8,
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        progress(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: "listing"))
        let spec = descriptor.downloadSpec
        let files = try await listRequiredFiles(spec: spec, session: session)
        try await download(files: files, spec: spec, to: directory, session: session, progress: progress)

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        _ = try await AsrModels.downloadAndLoad(
            to: directory,
            configuration: configuration,
            version: descriptor.version,
            encoderPrecision: descriptor.encoderPrecision,
            encoderComputeUnits: nil,
            progressHandler: { fluidProgress in
                progress(Self.progress(from: fluidProgress))
            }
        )
    }

    /// Downloads the optional CTC vocabulary-boost add-on without loading it.
    /// - Parameters:
    ///   - descriptor: Add-on descriptor to download.
    ///   - directory: The exact FluidAudio default cache directory.
    ///   - progress: Receives mapped progress snapshots.
    public func downloadVocabularyBoost(
        _ descriptor: ParakeetVocabularyBoostDescriptor = .ctc110m,
        to directory: URL,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        progress(ParakeetDownloadProgress(fractionCompleted: 0, phaseDescription: "listing"))
        let spec = descriptor.downloadSpec
        let files = try await listRequiredFiles(spec: spec, session: session)
        try await download(files: files, spec: spec, to: directory, session: session, progress: progress)
    }

    /// Returns whether the FluidAudio-required v3 int8 model files exist.
    /// - Parameter directory: The custom model directory root.
    /// - Returns: `true` when the model is installed.
    public static func modelsExist(at directory: URL) -> Bool {
        modelsExist(at: directory, descriptor: .parakeetV3Int8)
    }

    /// Returns whether the FluidAudio-required model files exist.
    /// - Parameters:
    ///   - directory: The custom model directory root.
    ///   - descriptor: Model catalog entry to check.
    /// - Returns: `true` when the model is installed.
    public static func modelsExist(at directory: URL, descriptor: ParakeetModelDescriptor) -> Bool {
        AsrModels.modelsExist(
            at: directory,
            version: descriptor.version,
            encoderPrecision: descriptor.encoderPrecision
        )
    }

    /// Returns whether the CTC vocabulary-boost files exist.
    public static func vocabularyBoostModelsExist(
        at directory: URL,
        descriptor: ParakeetVocabularyBoostDescriptor = .ctc110m
    ) -> Bool {
        descriptor.requiredFiles.exists(at: directory)
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

    private func listRequiredFiles(
        spec: ParakeetDownloadDescriptor,
        session: URLSession
    ) async throws -> [ParakeetModelDownloadFile] {
        let (data, response) = try await session.data(from: Self.repositoryTreeURL(for: spec))
        try Self.validateHTTPResponse(response, path: "repository tree")
        return try ParakeetModelDownloadFile.files(
            fromHuggingFaceTreeJSON: data,
            requiredFiles: spec.requiredFiles
        )
    }

    private func download(
        files: [ParakeetModelDownloadFile],
        spec: ParakeetDownloadDescriptor,
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
                spec: spec,
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
        spec: ParakeetDownloadDescriptor,
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
                    spec: spec,
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
        spec: ParakeetDownloadDescriptor,
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

        let url = Self.resolveURL(for: file.path, spec: spec)
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

    private static func repositoryTreeURL(for spec: ParakeetDownloadDescriptor) -> URL {
        URL(string: "https://huggingface.co/api/models/\(spec.repositoryPath)/tree/main?recursive=true")!
    }

    private static func repositoryResolveBaseURL(for spec: ParakeetDownloadDescriptor) -> URL {
        URL(string: "https://huggingface.co/\(spec.repositoryPath)/resolve/main/")!
    }

    private static func resolveURL(for path: String, spec: ParakeetDownloadDescriptor) -> URL {
        path.split(separator: "/", omittingEmptySubsequences: true).reduce(repositoryResolveBaseURL(for: spec)) { url, component in
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
