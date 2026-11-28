import CmuxSwiftRender
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

    /// Discovers custom sidebar source files in a directory.
    ///
    /// Swift files are preferred over JSON files with the same base name.
    public func discover(in directory: URL, name requestedName: String? = nil) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        // Priority when several extensions share a base name: js > swift > json.
        func priority(_ ext: String) -> Int {
            switch ext {
            case "js": return 3
            case "swift": return 2
            case "json": return 1
            default: return 0
            }
        }
        var fileByName: [String: URL] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard priority(ext) > 0 else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let requestedName, requestedName != name { continue }
            if let existing = fileByName[name], priority(existing.pathExtension.lowercased()) >= priority(ext) { continue }
            fileByName[name] = url
        }

        return fileByName.keys.sorted().compactMap { fileByName[$0] }
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
        let ext = fileURL.pathExtension.lowercased()
        let kind: CustomSidebarFileKind
        switch ext {
        case "js": kind = .js
        case "swift": kind = .swift
        default: kind = .json
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
            case .js:
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                if let message = SidebarJSRuntime.validate(source: source, state: dataContext ?? fallbackDataContext) {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: message
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

    /// The sample workspace's pull request; the builder emits the same object as `pr` and inside `prs`.
    private static let samplePullRequest: SwiftValue = .object([
        "number": .int(5812),
        "label": .string("PR 5812"),
        "url": .string("https://github.com/manaflow-ai/cmux/pull/5812"),
        "status": .string("open"),
        "stale": .bool(false),
        "branch": .string("main"),
    ])

    /// A pull request with no branch; the builder adds `branch` only when the pull request has one.
    private static let sampleBranchlessPullRequest: SwiftValue = .object([
        "number": .int(5790),
        "label": .string("PR 5790"),
        "url": .string("https://github.com/manaflow-ai/cmux/pull/5790"),
        "status": .string("merged"),
        "stale": .bool(false),
    ])

    /// Representative data context used when validating Swift sidebars outside a live render.
    ///
    /// Every field present carries the type CustomSidebarDataContextBuilder emits
    /// for a real render: the populated workspace sample uses the builder's
    /// object/int shapes for its workspace-level optionals, and the quiet workspace
    /// omits every optional the builder omits when absent, so validation exercises
    /// both paths (#7944). The linked workspace's pull request has no `branch`,
    /// which the builder also omits when a pull request has none. The sample has no
    /// `agents`, `emoji` or `group` and no tabs, so per-agent and per-tab shapes are
    /// not exercised.
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
                "unread": .int(2),
                "status": .string("working"),
                "tabs": .array([]),
                "tabCount": .int(0),
                "description": .string("Crash fix"),
                "color": .string("#0A84FF"),
                "branch": .string("main"),
                "dirty": .bool(true),
                "pr": samplePullRequest,
                "prs": .array([samplePullRequest]),
                "progress": .object([
                    "value": .double(0.42),
                    "label": .string("Running tests"),
                ]),
                "latestMessage": .string("Waiting for review"),
                "latestPrompt": .string("Fix the crash and add coverage"),
                "latestAt": .int(1_779_999_400),
                "remote": .object([
                    "target": .string("aws-m4pro-1"),
                    "state": .string("connected"),
                    "connected": .bool(true),
                ]),
            ]),
            .object([
                "id": .string("workspace-quiet"),
                "title": .string("Quiet Workspace"),
                "selected": .bool(false),
                "pinned": .bool(false),
                "index": .int(1),
                "directory": .string("~/other"),
                "ports": .array([]),
                "portCount": .int(0),
                "unread": .int(0),
                "status": .string("todo"),
                "tabs": .array([]),
                "tabCount": .int(0),
            ]),
            .object([
                "id": .string("workspace-linked"),
                "title": .string("Linked Workspace"),
                "selected": .bool(false),
                "pinned": .bool(false),
                "index": .int(2),
                "directory": .string("~/linked"),
                "ports": .array([]),
                "portCount": .int(0),
                "unread": .int(0),
                "status": .string("todo"),
                "tabs": .array([]),
                "tabCount": .int(0),
                "pr": sampleBranchlessPullRequest,
                "prs": .array([sampleBranchlessPullRequest]),
            ]),
        ]),
        "groups": .array([
            .object([
                "id": .string("group-sample"),
                "name": .string("Sample Group"),
                "collapsed": .bool(false),
                "pinned": .bool(false),
                "anchorId": .string("workspace-sample"),
            ])
        ]),
        "workspaceCount": .int(3),
        "selectedTitle": .string("Sample Workspace"),
        "selectedId": .string("workspace-sample"),
        "unreadTotal": .int(2),
        // One instant: epoch 1_780_000_000 is Thursday 20:26:40 UTC (Calendar
        // weekday 5), ten minutes after the sample latestAt. The display fields
        // are UTC; a real render derives them in the local time zone.
        "clock": .object([
            "time": .string("20:26:40"),
            "hour": .int(20),
            "minute": .int(26),
            "second": .int(40),
            "weekday": .int(5),
            "epoch": .int(1_780_000_000),
        ]),
    ]

    private func missingEntry(name: String, directory: URL) -> CustomSidebarValidationEntry {
        let candidates = ["js", "swift", "json"].map { directory.appendingPathComponent("\(name).\($0)") }
        let missingURL = candidates.first { fileManager.fileExists(atPath: $0.path) } ?? candidates[2]
        let kind: CustomSidebarFileKind
        switch missingURL.pathExtension.lowercased() {
        case "js": kind = .js
        case "swift": kind = .swift
        default: kind = .json
        }
        return CustomSidebarValidationEntry(
            name: name,
            fileURL: missingURL,
            kind: kind,
            errorMessage: String(localized: "sidebar.custom.validation.fileMissing", defaultValue: "Sidebar file is missing.")
        )
    }
}

private func decodingPath(_ ctx: DecodingError.Context) -> String {
    let parts = ctx.codingPath.map(\.stringValue)
    return parts.isEmpty ? String(localized: "sidebar.custom.validation.rootPath", defaultValue: "root") : parts.joined(separator: " › ")
}
