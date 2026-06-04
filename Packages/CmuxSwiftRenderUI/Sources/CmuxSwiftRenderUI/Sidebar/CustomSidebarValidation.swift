import CmuxSwiftRender
import Foundation

public extension Notification.Name {
    static let customSidebarReloadRequested = Notification.Name("cmux.customSidebarReloadRequested")
}

public enum CustomSidebarFileKind: String, Sendable {
    case swift
    case json
}

public struct CustomSidebarValidationEntry: Equatable, Sendable {
    public let name: String
    public let fileURL: URL
    public let kind: CustomSidebarFileKind
    public let errorMessage: String?

    public init(name: String, fileURL: URL, kind: CustomSidebarFileKind, errorMessage: String?) {
        self.name = name
        self.fileURL = fileURL
        self.kind = kind
        self.errorMessage = errorMessage
    }

    public var isValid: Bool { errorMessage == nil }
}

public struct CustomSidebarValidationReport: Equatable, Sendable {
    public let entries: [CustomSidebarValidationEntry]

    public init(entries: [CustomSidebarValidationEntry]) {
        self.entries = entries
    }

    public var validCount: Int {
        entries.filter(\.isValid).count
    }

    public var errorCount: Int {
        entries.count - validCount
    }

    public var validNames: [String] {
        entries.filter(\.isValid).map(\.name)
    }
}

public enum CustomSidebarValidation {
    public static func discover(in directory: URL, name requestedName: String? = nil) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var fileByName: [String: URL] = [:]
        for url in entries {
            let ext = url.pathExtension.lowercased()
            guard ext == "swift" || ext == "json" else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if let requestedName, requestedName != name { continue }
            if fileByName[name]?.pathExtension.lowercased() == "swift" { continue }
            fileByName[name] = url
        }

        return fileByName.keys.sorted().compactMap { fileByName[$0] }
    }

    public static func validate(
        directory: URL,
        name requestedName: String? = nil,
        dataContext: [String: SwiftValue] = defaultDataContext
    ) -> CustomSidebarValidationReport {
        let urls = discover(in: directory, name: requestedName)
        let entries = urls.map { validate(fileURL: $0, dataContext: dataContext) }
        return CustomSidebarValidationReport(entries: entries)
    }

    public static func validate(
        fileURL: URL,
        dataContext: [String: SwiftValue] = defaultDataContext
    ) -> CustomSidebarValidationEntry {
        let name = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.lowercased()
        let kind: CustomSidebarFileKind = ext == "swift" ? .swift : .json

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CustomSidebarValidationEntry(
                name: name,
                fileURL: fileURL,
                kind: kind,
                errorMessage: "Sidebar file is missing."
            )
        }

        do {
            switch kind {
            case .swift:
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let node = SwiftViewInterpreter().evaluate(source, state: dataContext)
                guard node != nil else {
                    return CustomSidebarValidationEntry(
                        name: name,
                        fileURL: fileURL,
                        kind: kind,
                        errorMessage: "No supported SwiftUI view found."
                    )
                }
            case .json:
                let data = try Data(contentsOf: fileURL)
                _ = try JSONDecoder().decode(DSLDocument.self, from: data)
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

    public static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case let .keyNotFound(key, ctx):
                return "Missing key '\(key.stringValue)' at \(path(ctx))"
            case let .typeMismatch(_, ctx):
                return "Type mismatch at \(path(ctx)): \(ctx.debugDescription)"
            case let .valueNotFound(_, ctx):
                return "Missing value at \(path(ctx))"
            case let .dataCorrupted(ctx):
                return "Invalid JSON at \(path(ctx)): \(ctx.debugDescription)"
            @unknown default:
                return decoding.localizedDescription
            }
        }
        return (error as NSError).localizedDescription
    }

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

    private static func path(_ ctx: DecodingError.Context) -> String {
        let parts = ctx.codingPath.map(\.stringValue)
        return parts.isEmpty ? "root" : parts.joined(separator: " › ")
    }
}
