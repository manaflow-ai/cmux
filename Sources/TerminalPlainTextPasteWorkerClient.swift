import AppKit
import Foundation
import UniformTypeIdentifiers

/// Runs the small isolated helper used for pasteboards that advertise only
/// plain text, keeping the full application worker for every other payload.
struct TerminalPlainTextPasteWorkerClient: Sendable {
    enum Outcome: Sendable {
        case prepared(String)
        case rejected
        case fallBackToFullPreparation
    }

    private enum ResponseStatus: String, Decodable {
        case text
        case empty
        case stale
    }

    private struct Response: Decodable {
        let status: ResponseStatus
        let destination: String?
        let filename: String?
    }

    static let workerModeArgument = "--cmux-plain-text-paste-worker"
    static let workingDirectoryArgument =
        "--cmux-paste-preparation-working-directory"
    static let requestFilename = "request.json"
    static let responseFilename = "response.json"
    static let payloadFilename = "text-payload.txt"
    static let maximumPayloadByteCount = 16 * 1024 * 1024
    static let ineligibleExitStatus: Int32 = 73

    private let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    @concurrent
    func prepare(
        _ request: TerminalPastePreparationRequest
    ) async throws -> Outcome {
        guard isEligible(request) else {
            return .fallBackToFullPreparation
        }

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
        if status == Self.ineligibleExitStatus {
            return .fallBackToFullPreparation
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
              responseSize <= 4 * 1024 else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
        let responseData = try Data(
            contentsOf: responseURL,
            options: [.mappedIfSafe]
        )
        guard let response = try? JSONDecoder().decode(
            Response.self,
            from: responseData
        ) else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }

        switch response.status {
        case .empty, .stale:
            return .rejected
        case .text:
            guard response.destination == "terminal",
                  response.filename == Self.payloadFilename else {
                throw TerminalPastePreparationWorkerError.invalidWorkerResponse
            }
            let payloadURL = workingDirectory.appendingPathComponent(
                Self.payloadFilename
            )
            let payloadValues = try payloadURL.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ]
            )
            guard payloadValues.isRegularFile == true,
                  payloadValues.isSymbolicLink != true,
                  let payloadSize = payloadValues.fileSize,
                  payloadSize > 0,
                  payloadSize <= Self.maximumPayloadByteCount else {
                throw TerminalPastePreparationWorkerError.invalidWorkerResponse
            }
            let payload = try Data(
                contentsOf: payloadURL,
                options: [.mappedIfSafe]
            )
            guard let text = String(data: payload, encoding: .utf8) else {
                throw TerminalPastePreparationWorkerError.invalidWorkerResponse
            }
            return .prepared(text)
        }
    }

    private nonisolated func isEligible(
        _ request: TerminalPastePreparationRequest
    ) -> Bool {
        guard case .paste? = request.mode,
              case .terminal? = request.destination else {
            return false
        }
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(request.pasteboard.pasteboardName)
        )
        let types = pasteboard.types ?? []
        guard !types.isEmpty else { return false }
        var hasPlainText = false
        for type in types {
            guard !Self.isDisallowed(type) else { return false }
            hasPlainText = hasPlainText || Self.isPlainText(type)
        }
        return hasPlainText
    }

    private nonisolated static func isDisallowed(
        _ type: NSPasteboard.PasteboardType
    ) -> Bool {
        if type == .html || type == .rtf || type == .rtfd ||
           type == .fileURL || type == .URL ||
           type == NSPasteboard.PasteboardType("NSFilenamesPboardType") ||
           type == NSPasteboard.PasteboardType(
               "com.apple.pasteboard.promised-file-url"
           ) {
            return true
        }
        if type == .tiff || type == .png {
            return true
        }
        guard let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .image)
    }

    private nonisolated static func isPlainText(
        _ type: NSPasteboard.PasteboardType
    ) -> Bool {
        if type == .string || type == NSPasteboard.PasteboardType(
            "public.utf8-plain-text"
        ) {
            return true
        }
        guard !isDisallowed(type),
              let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .plainText)
    }

    private nonisolated func makeWorkingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-paste-preparation-(UUID().uuidString)",
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
}
