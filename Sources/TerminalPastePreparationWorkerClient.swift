import CmuxTerminal
import Foundation

/// Launches one killable paste worker and adopts its validated output files.
struct TerminalPastePreparationWorkerClient: Sendable {
    static let workerModeArgument = "--cmux-paste-preparation-worker"
    static let workingDirectoryArgument =
        "--cmux-paste-preparation-working-directory"
    static let requestFilename = "request.json"
    static let responseFilename = "response.json"
    static let maximumResponseSize = 12 * 1024 * 1024
    static let workingDirectoryPrefix = "cmux-paste-preparation-"

    private let executableURL: URL
    private let pasteboardService: TerminalPasteboardService?
    private let plainTextExecutableURL: URL?

    init(
        executableURL: URL,
        pasteboardService: TerminalPasteboardService,
        plainTextExecutableURL: URL? = Bundle.main.url(
            forResource: "cmux-paste-text-worker",
            withExtension: nil,
            subdirectory: "bin"
        )
    ) {
        self.executableURL = executableURL
        self.pasteboardService = pasteboardService
        self.plainTextExecutableURL = plainTextExecutableURL
    }

    private init(executableURL: URL) {
        self.executableURL = executableURL
        pasteboardService = nil
        plainTextExecutableURL = nil
    }

    static func reexecingCurrentBinary(
        pasteboardService: TerminalPasteboardService
    ) -> TerminalPastePreparationWorkerClient {
        let binary = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return TerminalPastePreparationWorkerClient(
            executableURL: binary,
            pasteboardService: pasteboardService,
            plainTextExecutableURL: Bundle.main.url(
                forResource: "cmux-paste-text-worker",
                withExtension: nil,
                subdirectory: "bin"
            )
        )
    }

    static func snapshottingWithCurrentBinary()
        -> TerminalPastePreparationWorkerClient
    {
        let binary = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return TerminalPastePreparationWorkerClient(executableURL: binary)
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    func captureSnapshot(
        _ request: TerminalPasteboardContentsCaptureRequest
    ) async throws -> TerminalPasteboardContentsSnapshot? {
        let result = try await prepare(
            TerminalPastePreparationRequest(snapshot: request)
        )
        guard case .pasteboardSnapshot(let snapshot) = result else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
        return snapshot
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    func prepare(
        _ request: TerminalPastePreparationRequest
    ) async throws -> TerminalPastePreparationResult {
        try Task.checkCancellation()
        let workingDirectory = try makeWorkingDirectory()
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
        }

        let requestURL = workingDirectory.appendingPathComponent(
            Self.requestFilename
        )
        try writeSecurely(
            JSONEncoder().encode(request),
            to: requestURL
        )

        // Providers (even plain-text providers) remain killable. Only the
        // helper inspects pasteboard flavors; no provider read enters the app.
        // An explicit ineligible result is the only reason to retry in the full
        // worker. A stalled/crashed provider must fail locally, not run twice.
        var status: Int32 = 73
        if case .paste? = request.mode,
           case .terminal? = request.destination,
           let plainTextExecutableURL {
            status = try await runWorker(
                executable: plainTextExecutableURL,
                modeArgument: "--cmux-plain-text-paste-worker",
                workingDirectory: workingDirectory
            )
        }
        if status == 73 {
            status = try await runWorker(
                executable: executableURL,
                modeArgument: Self.workerModeArgument,
                workingDirectory: workingDirectory
            )
        }
        guard status == 0 else {
            throw TerminalPastePreparationWorkerError.workerExited(status)
        }

        let responseURL = workingDirectory.appendingPathComponent(
            Self.responseFilename
        )
        let responseValues = try responseURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        guard responseValues.isRegularFile == true,
              responseValues.isSymbolicLink != true,
              let responseSize = responseValues.fileSize,
              responseSize > 0,
              responseSize <= Self.maximumResponseSize else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
        let responseData = try Data(
            contentsOf: responseURL,
            options: [.mappedIfSafe]
        )
        guard let response = try? JSONDecoder().decode(
                TerminalPastePreparationWorkerResponse.self,
                from: responseData
              ) else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
        let result = try resolveResult(
            from: response,
            workingDirectory: workingDirectory
        )
        if case .pasteboardSnapshot = result {
            guard response.ownedTemporaryImageNames.isEmpty else {
                throw TerminalPastePreparationWorkerError
                    .invalidWorkerResponse
            }
            return result
        }
        guard let pasteboardService else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
        return try adoptWorkerFiles(
            in: result,
            ownedTemporaryImageNames: response.ownedTemporaryImageNames,
            workingDirectory: workingDirectory,
            pasteboardService: pasteboardService
        )
    }

    private nonisolated func runWorker(
        executable: URL,
        modeArgument: String,
        workingDirectory: URL
    ) async throws -> Int32 {
        try Task.checkCancellation()
        let process = TerminalPastePreparationProcess(
            executableURL: executable,
            arguments: [modeArgument, Self.workingDirectoryArgument, workingDirectory.path],
            environment: ProcessInfo.processInfo.environment
        )
        let status = try await process.run()
        try Task.checkCancellation()
        return status
    }

    private nonisolated func makeWorkingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(Self.workingDirectoryPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private nonisolated func writeSecurely(
        _ data: Data,
        to fileURL: URL
    ) throws {
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private nonisolated func adoptWorkerFiles(
        in result: TerminalPastePreparationResult,
        ownedTemporaryImageNames: [String],
        workingDirectory: URL,
        pasteboardService: TerminalPasteboardService
    ) throws -> TerminalPastePreparationResult {
        // URLs outside this private directory are pre-existing pasteboard file
        // URLs and intentionally retain their identity. Every worker-created
        // output must be directory-local and exactly covered by the owned set.
        let workerFileURLs = result.transferredFileURLs.filter {
            $0.standardizedFileURL.deletingLastPathComponent()
                == workingDirectory.standardizedFileURL
        }
        let workerFileNames = Set(workerFileURLs.map(\.lastPathComponent))
        let claimedNames = Set(ownedTemporaryImageNames)
        guard claimedNames.count
                == ownedTemporaryImageNames.count,
              claimedNames == workerFileNames,
              claimedNames.allSatisfy(isSafeFilename) else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }

        var adoptedURLs: [URL] = []
        do {
            var replacementsByPath: [String: URL] = [:]
            for name in ownedTemporaryImageNames {
                let sourceURL = workingDirectory.appendingPathComponent(name)
                let adoptedURL = try pasteboardService
                    .adoptTemporaryImageFile(
                        sourceURL,
                        from: workingDirectory
                    )
                adoptedURLs.append(adoptedURL)
                replacementsByPath[
                    sourceURL.standardizedFileURL.path
                ] = adoptedURL
            }
            return result.replacingTransferredFileURLs(
                replacementsByPath
            )
        } catch {
            pasteboardService.cleanupTransferredTemporaryImageFiles(
                adoptedURLs
            )
            throw error
        }
    }

    private nonisolated func resolveResult(
        from response: TerminalPastePreparationWorkerResponse,
        workingDirectory: URL
    ) throws -> TerminalPastePreparationResult {
        switch (response.result, response.textPayload) {
        case (.some(let result), nil):
            return result
        case (nil, .some(let payload)):
            guard payload.filename
                    == TerminalPastePreparationWorkerTextPayload.filename,
                  isSafeFilename(payload.filename),
                  !response.ownedTemporaryImageNames.contains(
                    payload.filename
                  ) else {
                throw TerminalPastePreparationWorkerError
                    .invalidWorkerResponse
            }
            let textURL = workingDirectory.appendingPathComponent(
                payload.filename
            )
            let values = try textURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize
                    <= TerminalPastePreparationWorkerTextPayload
                        .maximumByteCount else {
                throw TerminalPastePreparationWorkerError
                    .invalidWorkerResponse
            }
            let textData = try Data(
                contentsOf: textURL,
                options: [.mappedIfSafe]
            )
            guard let text = String(data: textData, encoding: .utf8) else {
                throw TerminalPastePreparationWorkerError
                    .invalidWorkerResponse
            }
            switch payload.destination {
            case .terminal:
                return .terminal(.insertText(text))
            case .composer:
                return .composer(.insertText(text))
            }
        default:
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
    }

    private nonisolated func isSafeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
            && !name.contains("/")
    }
}
