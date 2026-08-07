import CmuxFoundation
import CmuxSwiftRender
import Darwin
import Foundation

/// Validates custom sidebar files using the same JSON schema and Swift interpreter as rendering.
public struct CustomSidebarValidator {
    private let fileManager: FileManager
    private let fallbackDataContext: [String: SwiftValue]

    /// Creates a validator with injectable filesystem and data-context dependencies.
    public init(
        fileManager: FileManager = .default,
        fallbackDataContext: [String: SwiftValue] = Self.defaultDataContext
    ) {
        self.fileManager = fileManager
        self.fallbackDataContext = fallbackDataContext
    }

    /// Discovers custom sidebar source files in a directory, one per sidebar name.
    ///
    /// Resolution order is ``CustomSidebarSource/fileExtensions`` — `.swift`, `.json`, `.html`,
    /// `.url` — the same order the render path and the picker use. Sharing it is the point: when the
    /// CLI resolved only `.swift`/`.json`, `cmux sidebar select board` on an HTML sidebar reported
    /// the file as missing while the picker showed it working, and `cmux sidebar validate` invented
    /// a `board.json` that had never existed.
    public func discover(in directory: URL, name requestedName: String? = nil) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var fileByName: [String: URL] = [:]
        for url in entries {
            guard let rank = Self.resolutionRank(of: url) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let requestedName, requestedName != name { continue }
            if let existing = fileByName[name],
               let existingRank = Self.resolutionRank(of: existing),
               existingRank <= rank {
                continue
            }
            fileByName[name] = url
        }

        return fileByName.keys.sorted().compactMap { fileByName[$0] }
    }

    /// Position of a file's extension in the shared resolution order, or `nil` if unrecognised.
    ///
    /// Matched exactly, not case-folded. Discovery reads the disk while name resolution builds
    /// `<name>.<ext>` from this same lowercase list, so folding here would let discovery report a
    /// `board.HTML` that resolution cannot then find on a case-sensitive volume.
    private static func resolutionRank(of url: URL) -> Int? {
        CustomSidebarSource.fileExtensions.firstIndex(of: url.pathExtension)
    }

    /// Validates every discovered sidebar, or one requested sidebar name.
    public func validate(
        directory: URL,
        name requestedName: String? = nil,
        dataContext: [String: SwiftValue]? = nil
    ) -> CustomSidebarValidationReport {
        let urls = discover(in: directory, name: requestedName)
        if let requestedName, urls.isEmpty {
            return CustomSidebarValidationReport(entries: [
                missingEntry(name: requestedName, directory: directory)
            ])
        }
        let context = dataContext ?? fallbackDataContext
        let entries = urls.map { validate(fileURL: $0, dataContext: context) }
        return CustomSidebarValidationReport(entries: entries)
    }

    /// Validates a specific sidebar file URL.
    public func validate(
        fileURL: URL,
        dataContext: [String: SwiftValue]? = nil
    ) -> CustomSidebarValidationEntry {
        let name = fileURL.deletingPathExtension().lastPathComponent
        guard let kind = CustomSidebarFileKind(fileURL: fileURL), Self.resolutionRank(of: fileURL) != nil else {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: .json,
                errorMessage: String(
                    localized: "sidebar.custom.validation.unsupportedExtension",
                    defaultValue: "Sidebar file must be .swift, .json, .html, or .url."
                )
            )
        }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
            )
        }

        do {
            switch kind {
            case .swift:
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let node = SwiftViewInterpreter().evaluate(source, state: dataContext ?? fallbackDataContext)
                guard node != nil else {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: String(localized: "sidebar.custom.noView", defaultValue: "No supported SwiftUI view found.")
                    )
                }
            case .json:
                let data = try Data(contentsOf: fileURL)
                _ = try JSONDecoder().decode(DSLDocument.self, from: data)
            case .html:
                // The markup is validated by rendering it, not by parsing it here: HTML has no
                // failure a parser could report that a browser would not simply recover from, so a
                // "your markup is wrong" verdict from cmux would be wrong more often than the page
                // is. What can genuinely fail is getting at the bytes at all, and existence does not
                // establish that — a directory exists, and so does a file the user cannot read.
                // Both mount and render blank, which is the failure this command exists to pre-empt.
                if isDirectory(fileURL) {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: String(
                            localized: "sidebar.custom.validation.documentIsDirectory",
                            defaultValue: "Sidebar .html path is a directory, not a document."
                        )
                    )
                }
                guard isReadableRegularFile(fileURL) else {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: String(
                            localized: "sidebar.custom.validation.readFailed",
                            defaultValue: "Failed to read sidebar file."
                        )
                    )
                }
            case .url:
                if let problem = CustomSidebarWebSourceProblem.diagnose(urlFile: fileURL) {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: describe(problem)
                    )
                }
            }
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: nil
            )
        } catch {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: describe(error)
            )
        }
    }

    /// Converts a web-source problem into sidebar-facing text.
    ///
    /// Says which scheme was rejected when there was one. "Invalid URL" sends the author back to
    /// re-read a file they have already read; "cmux sidebars cannot open 'file' URLs" tells them
    /// what to change.
    ///
    /// - Parameter problem: The diagnosed problem.
    public func describe(_ problem: CustomSidebarWebSourceProblem) -> String {
        switch problem {
        case .unreadable:
            return String(
                localized: "sidebar.custom.validation.readFailed",
                defaultValue: "Failed to read sidebar file."
            )
        case .tooLarge:
            return String(
                localized: "sidebar.custom.validation.urlFileTooLarge",
                defaultValue: "Sidebar .url file is too large to be a shortcut file."
            )
        case .noURL:
            return String(
                localized: "sidebar.custom.validation.urlFileEmpty",
                defaultValue: "Sidebar .url file does not contain a URL."
            )
        case .missingHost:
            return String(
                localized: "sidebar.custom.validation.urlFileNoHost",
                defaultValue: "Sidebar .url file's URL has no host to load from."
            )
        case let .unsupportedScheme(scheme):
            guard let scheme else {
                return String(
                    localized: "sidebar.custom.validation.urlFileNoScheme",
                    defaultValue: "Sidebar .url file must contain an http or https URL."
                )
            }
            return String(
                format: String(
                    localized: "sidebar.custom.validation.urlFileScheme",
                    defaultValue: "Sidebar .url file must be http or https, not '%@'."
                ),
                scheme
            )
        }
    }

    /// Whether a path opens immediately as a readable regular file.
    ///
    /// One byte is enough to establish readability, including EOF for an empty document. Opening with
    /// `O_NONBLOCK` and checking `fstat` first rejects FIFOs, sockets, and devices without waiting on
    /// them, while following ordinary symlinks to regular files just as WebKit does.
    private func isReadableRegularFile(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var metadata = Darwin.stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return false
        }

        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count >= 0 { return true }
            if errno != EINTR { return false }
        }
    }

    /// Whether a path is a directory.
    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Converts decoding and filesystem errors into sidebar-facing text.
    public func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.missingKey", defaultValue: "Missing key '%@' at %@"),
                    key.stringValue,
                    decodingPath(ctx)
                )
            case let .typeMismatch(_, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.typeMismatch", defaultValue: "Type mismatch at %@"),
                    decodingPath(ctx)
                )
            case let .valueNotFound(_, ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.missingValue", defaultValue: "Missing value at %@"),
                    decodingPath(ctx)
                )
            case let .dataCorrupted(ctx):
                return String(
                    format: String(localized: "sidebar.custom.validation.invalidJSON", defaultValue: "Invalid JSON at %@"),
                    decodingPath(ctx)
                )
            @unknown default:
                return String(localized: "sidebar.custom.validation.decodeFailed", defaultValue: "Failed to decode sidebar JSON.")
            }
        }
        return String(localized: "sidebar.custom.validation.readFailed", defaultValue: "Failed to read sidebar file.")
    }

    /// Representative data context used when validating Swift sidebars outside a live render.
    public static let defaultDataContext: [String: SwiftValue] = [
        "workspaces": .array([
            .object([
                "id": .string("workspace-sample"),
                "title": .string("Sample Workspace"),
                "selected": .bool(true),
                "pinned": .bool(false),
                "index": .int(0),
                "directory": .string("~/project"),
                "ports": .array([.int(3000)]),
                "portCount": .int(1),
                "unread": .int(0),
                "tabs": .array([]),
                "tabCount": .int(0),
                "description": .string(""),
                "color": .string(""),
                "branch": .string("main"),
                "dirty": .bool(false),
                "pr": .string(""),
                "prs": .array([]),
                "progress": .string(""),
                "latestMessage": .string(""),
                "latestPrompt": .string(""),
                "latestAt": .string(""),
                "remote": .string("")
            ])
        ]),
        "workspaceCount": .int(1),
        "selectedTitle": .string("Sample Workspace"),
        "selectedId": .string("workspace-sample"),
        "unreadTotal": .int(0),
        "clock": .string("12:00")
    ]

    /// Reports a name that resolved to no file.
    ///
    /// The reported path is the `.swift` one the author would create, not a guess at which of four
    /// extensions they meant. Naming a `.json` file that was never written — the previous behaviour,
    /// which surfaced as `cmux sidebar validate board` saying `board.json` is missing for a sidebar
    /// written as `board.html` — sends the author to a path that does not and should not exist.
    private func missingEntry(name: String, directory: URL) -> CustomSidebarValidationEntry {
        CustomSidebarValidationEntry(
            name: name,
            fileURL: directory.appendingPathComponent("\(name).swift"),
            kind: .swift,
            errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
        )
    }
}

private func decodingPath(_ ctx: DecodingError.Context) -> String {
    let parts = ctx.codingPath.map(\.stringValue)
    return parts.isEmpty ? String(localized: "sidebar.custom.validation.rootPath", defaultValue: "root") : parts.joined(separator: " › ")
}
