import AppKit
import CmuxSocketControl
import Bonsplit
import Foundation
import UniformTypeIdentifiers


// MARK: - Default Terminal File Open Requests
struct TerminalDefaultFileOpenRequest: Equatable {
    let fileURL: URL
    let workingDirectory: String
    let initialInput: String

    init?(fileURL: URL, contentType: UTType? = nil, isExecutable: Bool? = nil) {
        guard fileURL.isFileURL else { return nil }
        let standardizedURL = fileURL.standardizedFileURL
        let directoryCheckURL = standardizedURL.resolvingSymlinksInPath()
        let resourceValues = try? directoryCheckURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues?.isDirectory != true else { return nil }
        let resolvedContentType = contentType ?? Self.contentType(for: standardizedURL)
        let resolvedIsExecutable = isExecutable ?? Self.isExecutableFile(directoryCheckURL)
        guard Self.shouldRunInTerminal(
            fileURL: standardizedURL,
            contentType: resolvedContentType,
            isExecutable: resolvedIsExecutable
        ) else {
            return nil
        }

        self.fileURL = standardizedURL
        self.workingDirectory = standardizedURL.deletingLastPathComponent().path(percentEncoded: false)
        self.initialInput = "\(Self.shellSingleQuoted(standardizedURL.path(percentEncoded: false)))\n"
    }

    static func requests(from urls: [URL]) -> [TerminalDefaultFileOpenRequest] {
        var seen: Set<String> = []
        var requests: [TerminalDefaultFileOpenRequest] = []
        for url in urls {
            guard let request = TerminalDefaultFileOpenRequest(fileURL: url) else { continue }
            let path = request.fileURL.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            requests.append(request)
        }
        return requests
    }

    private static func contentType(for fileURL: URL) -> UTType? {
        try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    private static func isExecutableFile(_ fileURL: URL) -> Bool {
        if (try? fileURL.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true {
            return true
        }
        return FileManager.default.isExecutableFile(atPath: fileURL.path(percentEncoded: false))
    }

    private static func shouldRunInTerminal(fileURL: URL, contentType: UTType?, isExecutable: Bool) -> Bool {
        if isTerminalShellScript(fileURL: fileURL, contentType: contentType) {
            return true
        }
        return contentType?.conforms(to: .unixExecutable) == true || isExecutable
    }

    private static func isTerminalShellScript(fileURL: URL, contentType: UTType?) -> Bool {
        if contentType?.identifier == "com.apple.terminal.shell-script" {
            return true
        }
        switch fileURL.pathExtension.lowercased() {
        case "command", "tool":
            return true
        default:
            return false
        }
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

