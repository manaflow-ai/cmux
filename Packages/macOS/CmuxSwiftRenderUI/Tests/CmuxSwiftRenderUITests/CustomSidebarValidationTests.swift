import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar validation")
struct CustomSidebarValidationTests {
    private let validator = CustomSidebarValidator()

    @Test("discovers one file per sidebar name and prefers Swift")
    func discoversSwiftBeforeJSON() throws {
        let directory = try temporaryDirectory()
        try """
        Text("Swift")
        """.write(to: directory.appendingPathComponent("finder.swift"), atomically: true, encoding: .utf8)
        try """
        {"version":1,"root":{"type":"text","text":"JSON"}}
        """.write(to: directory.appendingPathComponent("finder.json"), atomically: true, encoding: .utf8)

        let urls = validator.discover(in: directory)

        #expect(urls.map(\.lastPathComponent) == ["finder.swift"])
    }

    @Test("reports JSON schema errors with root path")
    func reportsMissingJSONVersion() throws {
        let directory = try temporaryDirectory()
        try """
        {"root":{"type":"text","text":"Missing version"}}
        """.write(to: directory.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let report = validator.validate(directory: directory)

        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage == "Missing key 'version' at root")
    }

    @Test("reports Swift files that do not render a supported view")
    func reportsSwiftWithoutRenderableView() throws {
        let directory = try temporaryDirectory()
        try """
        let answer = 42
        """.write(to: directory.appendingPathComponent("broken.swift"), atomically: true, encoding: .utf8)

        let report = validator.validate(directory: directory)

        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage == "No supported SwiftUI view found.")
    }

    @Test("reports a missing requested sidebar name")
    func reportsMissingRequestedName() throws {
        let directory = try temporaryDirectory()

        let report = validator.validate(directory: directory, name: "missing")

        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.names == ["missing"])
        #expect(report.entries.first?.name == "missing")
        #expect(report.entries.first?.errorMessage == "Sidebar file is missing.")
    }

    @Test("downloadable custom sidebar examples validate")
    func downloadableCustomSidebarExamplesValidate() throws {
        let directory = examplesDirectory()
        let report = validator.validate(directory: directory, dataContext: Self.richSidebarContext)

        #expect(report.names.sorted() == ["finder", "status-board"])
        #expect(report.validCount == 2)
        #expect(report.errorCount == 0)
    }

    @MainActor
    @Test("model re-resolves preferred file kind on reload")
    func modelReresolvesPreferredFileKind() throws {
        let directory = try temporaryDirectory()
        let jsonURL = directory.appendingPathComponent("finder.json")
        let swiftURL = directory.appendingPathComponent("finder.swift")

        try """
        {"version":1,"root":{"type":"text","text":"JSON"}}
        """.write(to: jsonURL, atomically: true, encoding: .utf8)

        let model = CustomSidebarModel(fileURL: jsonURL)
        model.reload()
        guard case .json = model.state else {
            Issue.record("Expected JSON sidebar state before Swift file exists")
            return
        }

        try """
        Text("Swift")
        """.write(to: swiftURL, atomically: true, encoding: .utf8)

        model.reload()
        guard case let .swiftSource(source) = model.state else {
            Issue.record("Expected Swift sidebar state after Swift file is added")
            return
        }
        #expect(source.contains("Text(\"Swift\")"))

        try FileManager.default.removeItem(at: swiftURL)

        model.reload()
        guard case .json = model.state else {
            Issue.record("Expected JSON sidebar state after Swift file is removed")
            return
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func examplesDirectory() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Examples/CustomSidebars", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("Examples/CustomSidebars", isDirectory: true)
    }

    private static let richSidebarContext: [String: SwiftValue] = [
        "workspaceCount": .int(3),
        "selectedTitle": .string("cmux"),
        "selectedId": .string("workspace-cmux"),
        "unreadTotal": .int(4),
        "clock": .object([
            "time": .string("14:32:10"),
            "hour": .int(14),
            "minute": .int(32),
            "second": .int(10),
            "weekday": .string("Thu"),
            "epoch": .int(1_780_000_000),
        ]),
        "workspaces": .array([
            .object([
                "id": .string("workspace-cmux"),
                "title": .string("cmux"),
                "selected": .bool(true),
                "pinned": .bool(true),
                "index": .int(0),
                "directory": .string("/Users/me/src/cmux"),
                "ports": .array([.int(3801), .int(5173)]),
                "portCount": .int(2),
                "unread": .int(2),
                "tabCount": .int(2),
                "description": .string("Crash fix"),
                "color": .string("#0A84FF"),
                "branch": .string("fix-crash-on-launch"),
                "dirty": .bool(true),
                "pr": .object([
                    "number": .int(5812),
                    "label": .string("PR 5812"),
                    "url": .string("https://github.com/manaflow-ai/cmux/pull/5812"),
                    "status": .string("open"),
                    "stale": .bool(false),
                    "branch": .string("fix-crash-on-launch"),
                ]),
                "prs": .array([]),
                "progress": .object([
                    "value": .double(0.64),
                    "label": .string("Tests running"),
                ]),
                "latestMessage": .string("Waiting for review"),
                "latestPrompt": .string("Fix the crash and add coverage"),
                "latestAt": .int(1_779_999_400),
                "remote": .object([
                    "target": .string("aws-m4pro-1"),
                    "state": .string("connected"),
                    "connected": .bool(true),
                ]),
                "tabs": .array([
                    .object([
                        "id": .string("surface-terminal"),
                        "title": .string("Terminal"),
                        "focused": .bool(true),
                        "pinned": .bool(false),
                        "directory": .string("/Users/me/src/cmux"),
                        "branch": .string("fix-crash-on-launch"),
                        "dirty": .bool(true),
                        "ports": .array([.int(3801)]),
                    ]),
                    .object([
                        "id": .string("surface-browser"),
                        "title": .string("Preview"),
                        "focused": .bool(false),
                        "pinned": .bool(true),
                        "directory": .string("/Users/me/src/cmux/web"),
                        "branch": .string("fix-crash-on-launch"),
                        "dirty": .bool(false),
                        "ports": .array([.int(5173)]),
                    ]),
                ]),
            ]),
            .object([
                "id": .string("workspace-review"),
                "title": .string("review queue"),
                "selected": .bool(false),
                "pinned": .bool(false),
                "index": .int(1),
                "directory": .string("/Users/me/src/review"),
                "ports": .array([]),
                "portCount": .int(0),
                "unread": .int(2),
                "tabCount": .int(1),
                "description": .string("Review branch"),
                "branch": .string("main"),
                "dirty": .bool(false),
                "pr": .object([
                    "number": .int(5801),
                    "label": .string("PR 5801"),
                    "url": .string("https://github.com/manaflow-ai/cmux/pull/5801"),
                    "status": .string("merged"),
                    "stale": .bool(false),
                    "branch": .string("feat-sidebar"),
                ]),
                "prs": .array([]),
                "progress": .string(""),
                "latestMessage": .string("Merged"),
                "latestPrompt": .string(""),
                "latestAt": .int(1_779_996_000),
                "remote": .string(""),
                "tabs": .array([
                    .object([
                        "id": .string("surface-review"),
                        "title": .string("Review"),
                        "focused": .bool(false),
                        "pinned": .bool(false),
                        "directory": .string("/Users/me/src/review"),
                        "branch": .string("main"),
                        "dirty": .bool(false),
                        "ports": .array([]),
                    ]),
                ]),
            ]),
            .object([
                "id": .string("workspace-research"),
                "title": .string("research spike"),
                "selected": .bool(false),
                "pinned": .bool(false),
                "index": .int(2),
                "directory": .string("/Users/me/src/research"),
                "ports": .array([]),
                "portCount": .int(0),
                "unread": .int(0),
                "tabCount": .int(0),
                "description": .string(""),
                "branch": .string("main"),
                "dirty": .bool(false),
                "pr": .string(""),
                "prs": .array([]),
                "progress": .string(""),
                "latestMessage": .string(""),
                "latestPrompt": .string(""),
                "latestAt": .string(""),
                "remote": .string(""),
                "tabs": .array([]),
            ]),
        ]),
    ]
}
