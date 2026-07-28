import CmuxTerminal
import Foundation

/// Executes one synchronous pasteboard preparation in an isolated subprocess.
struct TerminalPastePreparationWorker {
    func run(arguments: [String]) -> Int32 {
        guard let workingDirectory = workingDirectory(from: arguments),
              isValidWorkingDirectory(workingDirectory) else {
            return 64
        }
        guard let supervisor = TerminalPastePreparationWorkerSupervisor(
            workingDirectory: workingDirectory
        ) else {
            return 71
        }
        supervisor.start()
        defer { supervisor.cancel() }

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
        let ownedNames: [String] = result.transferredFileURLs.compactMap { fileURL in
            guard pasteboardService.isOwnedTemporaryImageFile(fileURL) else {
                return nil
            }
            return fileURL.lastPathComponent
        }
        let response: TerminalPastePreparationWorkerResponse
        do {
            response = try workerResponse(
                for: result,
                ownedTemporaryImageNames: ownedNames,
                workingDirectory: workingDirectory
            )
        } catch {
            return 74
        }
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

    private func workerResponse(
        for result: TerminalPastePreparationResult,
        ownedTemporaryImageNames: [String],
        workingDirectory: URL
    ) throws -> TerminalPastePreparationWorkerResponse {
        let text: String
        let destination: TerminalPastePreparationDestination
        switch result {
        case .terminal(.insertText(let preparedText)):
            text = preparedText
            destination = .terminal
        case .composer(.insertText(let preparedText)):
            text = preparedText
            destination = .composer
        default:
            return TerminalPastePreparationWorkerResponse(
                result: result,
                textPayload: nil,
                ownedTemporaryImageNames: ownedTemporaryImageNames
            )
        }

        let filename = TerminalPastePreparationWorkerTextPayload.filename
        let textURL = workingDirectory.appendingPathComponent(filename)
        guard text.utf8.count
                <= TerminalPastePreparationWorkerTextPayload.maximumByteCount
        else {
            throw TerminalPastePreparationWorkerError.textPayloadTooLarge
        }
        try Data(text.utf8).write(to: textURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: textURL.path
        )
        return TerminalPastePreparationWorkerResponse(
            result: nil,
            textPayload: TerminalPastePreparationWorkerTextPayload(
                destination: destination,
                filename: filename
            ),
            ownedTemporaryImageNames: ownedTemporaryImageNames
        )
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
        let standardizedDirectory = directory.standardizedFileURL
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .standardizedFileURL
        let identifier = String(
            standardizedDirectory.lastPathComponent.dropFirst(
                TerminalPastePreparationWorkerClient
                    .workingDirectoryPrefix.count
            )
        )
        guard directory.isFileURL,
              standardizedDirectory.deletingLastPathComponent()
                == temporaryDirectory,
              standardizedDirectory.lastPathComponent.hasPrefix(
                TerminalPastePreparationWorkerClient.workingDirectoryPrefix
              ),
              UUID(uuidString: identifier) != nil,
              let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ) else {
            return false
        }
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }
}
