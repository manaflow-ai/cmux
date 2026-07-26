import CmuxTerminal
import Foundation

/// Executes one synchronous pasteboard preparation in an isolated subprocess.
struct TerminalPastePreparationWorker {
    func run(arguments: [String]) -> Int32 {
        guard let workingDirectory = workingDirectory(from: arguments),
              isValidWorkingDirectory(workingDirectory) else {
            return 64
        }

        let requestURL = workingDirectory.appendingPathComponent(
            TerminalPastePreparationWorkerClient.requestFilename
        )
        let responseURL = workingDirectory.appendingPathComponent(
            TerminalPastePreparationWorkerClient.responseFilename
        )
        guard let requestData = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(
                TerminalPastePreparationRequest.self,
                from: requestData
              ) else {
            return 65
        }

        let pasteboardService = TerminalPasteboardService(
            temporaryDirectory: workingDirectory
        )
        var shouldCleanupImages = true
        defer {
            if shouldCleanupImages {
                pasteboardService.cleanupAllOwnedTemporaryImageFiles()
            }
        }

        let result = TerminalPastePreparationOperation(
            pasteboardService: pasteboardService
        ).prepare(request: request)
        let ownedNames = result.transferredFileURLs.compactMap { fileURL in
            guard pasteboardService.isOwnedTemporaryImageFile(fileURL) else {
                return nil
            }
            return fileURL.lastPathComponent
        }
        let response = TerminalPastePreparationWorkerResponse(
            result: result,
            ownedTemporaryImageNames: ownedNames
        )
        guard let responseData = try? JSONEncoder().encode(response) else {
            return 66
        }
        do {
            try responseData.write(to: responseURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: responseURL.path
            )
        } catch {
            return 74
        }

        shouldCleanupImages = false
        return 0
    }

    private func workingDirectory(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(
            of: TerminalPastePreparationWorkerClient
                .workingDirectoryArgument
        ) else {
            return nil
        }
        let pathIndex = arguments.index(after: index)
        guard arguments.indices.contains(pathIndex) else { return nil }
        return URL(
            fileURLWithPath: arguments[pathIndex],
            isDirectory: true
        ).standardizedFileURL
    }

    private func isValidWorkingDirectory(_ directory: URL) -> Bool {
        guard directory.isFileURL,
              let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else {
            return false
        }
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }
}
