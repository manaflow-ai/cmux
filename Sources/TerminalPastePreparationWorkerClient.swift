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

    private let executableURL: URL
    private let pasteboardService: TerminalPasteboardService

    init(
        executableURL: URL,
        pasteboardService: TerminalPasteboardService
    ) {
        self.executableURL = executableURL
        self.pasteboardService = pasteboardService
    }

    static func reexecingCurrentBinary(
        pasteboardService: TerminalPasteboardService
    ) -> TerminalPastePreparationWorkerClient {
        let binary = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return TerminalPastePreparationWorkerClient(
            executableURL: binary,
            pasteboardService: pasteboardService
        )
    }

    nonisolated func prepare(
        _ request: TerminalPastePreparationRequest
    ) async throws -> TerminalPastePreparationResult {
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

        let process = TerminalPastePreparationProcess(
            executableURL: executableURL,
            arguments: [
                Self.workerModeArgument,
                Self.workingDirectoryArgument,
                workingDirectory.path,
            ],
            environment: ProcessInfo.processInfo.environment
        )
        let status = try await process.run()
        try Task.checkCancellation()
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
        return try adoptWorkerFiles(
            in: response,
            workingDirectory: workingDirectory
        )
    }

    private nonisolated func makeWorkingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-paste-preparation-\(UUID().uuidString)",
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
        in response: TerminalPastePreparationWorkerResponse,
        workingDirectory: URL
    ) throws -> TerminalPastePreparationResult {
        let workerFileURLs = response.result.transferredFileURLs.filter {
            $0.standardizedFileURL.deletingLastPathComponent()
                == workingDirectory.standardizedFileURL
        }
        let workerFileNames = Set(workerFileURLs.map(\.lastPathComponent))
        let claimedNames = Set(response.ownedTemporaryImageNames)
        guard claimedNames.count
                == response.ownedTemporaryImageNames.count,
              claimedNames == workerFileNames,
              claimedNames.allSatisfy(isSafeFilename) else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }

        var adoptedURLs: [URL] = []
        do {
            var replacementsByPath: [String: URL] = [:]
            for name in response.ownedTemporaryImageNames {
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
            return response.result.replacingTransferredFileURLs(
                replacementsByPath
            )
        } catch {
            pasteboardService.cleanupTransferredTemporaryImageFiles(
                adoptedURLs
            )
            throw error
        }
    }

    private nonisolated func isSafeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
            && !name.contains("/")
    }
}
