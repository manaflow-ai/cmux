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

    @Test("prefers a JS file over Swift and JSON with the same name")
    func discoversJSFirst() throws {
        let directory = try temporaryDirectory()
        try """
        sidebar(() => Text("JS"))
        """.write(to: directory.appendingPathComponent("finder.js"), atomically: true, encoding: .utf8)
        try """
        Text("Swift")
        """.write(to: directory.appendingPathComponent("finder.swift"), atomically: true, encoding: .utf8)

        let urls = validator.discover(in: directory)
        #expect(urls.map(\.lastPathComponent) == ["finder.js"])

        let report = validator.validate(directory: directory)
        #expect(report.errorCount == 0)
        #expect(report.entries.first?.kind == .js)
    }

    @Test("reports JS programs that throw")
    func reportsThrowingJSProgram() throws {
        let directory = try temporaryDirectory()
        try """
        sidebar(() => missingBuilder())
        """.write(to: directory.appendingPathComponent("broken.js"), atomically: true, encoding: .utf8)

        let report = validator.validate(directory: directory)
        #expect(report.validCount == 0)
        #expect(report.errorCount == 1)
        #expect(report.entries.first?.errorMessage?.isEmpty == false)
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
        // manifest.json is the built-in template catalog's index, not a sidebar.
        let sidebars = report.entries.filter { $0.name != "manifest" }

        #expect(sidebars.map(\.name).sorted() == [
            "activity", "agents-board", "agents-cards", "agents-dense", "agents-focus", "agents-timeline",
            "btop-agents", "clock", "compact", "finder", "focus", "kitchen-sink", "panel-info",
            "panel-sessions", "panel-subagents", "panel-todo", "ports", "status-board", "workspaces",
        ])
        #expect(sidebars.filter(\.isValid).count == 19)
        #expect(sidebars.filter { !$0.isValid }.map(\.name) == [])
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
                "status": .string("needs-attention"),
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
                "agents": .array([
                    .object([
                        "id": .string("session-claude-1"),
                        "kind": .string("claude"),
                        "name": .string("Claude"),
                        "status": .string("working"),
                        "sinceEpoch": .int(1_779_999_900),
                        "lastActivityAt": .int(1_779_999_960),
                        "title": .string("Fix the crash and add coverage"),
                        "panelId": .string("panel-terminal"),
                        "surfaceId": .string("surface-terminal"),
                        "directory": .string("/Users/me/src/cmux"),
                        "transcriptPath": .string("/Users/me/.claude/projects/cmux/session-claude-1.jsonl"),
                        "pid": .int(4242),
                        "children": .array([
                            .object([
                                "id": .string("task-1"),
                                "label": .string("Explore the render pipeline"),
                                "running": .bool(true),
                                "startedEpoch": .int(1_779_999_930),
                            ]),
                            .object([
                                "id": .string("task-2"),
                                "label": .string("Audit tests"),
                                "running": .bool(false),
                                "startedEpoch": .int(1_779_999_905),
                                "endedEpoch": .int(1_779_999_950),
                            ]),
                        ]),
                    ]),
                    .object([
                        "id": .string("session-codex-1"),
                        "kind": .string("codex"),
                        "name": .string("Codex"),
                        "status": .string("needs_input"),
                        "sinceEpoch": .int(1_779_999_800),
                        "lastActivityAt": .int(1_779_999_800),
                        "surfaceId": .string("surface-browser"),
                    ]),
                    .object([
                        "id": .string("session-ended-1"),
                        "kind": .string("claude"),
                        "name": .string("Claude"),
                        "status": .string("ended"),
                        "lastActivityAt": .int(1_779_990_000),
                        "title": .string("Earlier refactor"),
                    ]),
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
                "status": .string("review"),
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
                "status": .string("todo"),
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

@Suite("Custom sidebar sample data context")
struct CustomSidebarSampleContextTests {
    /// The workspaces the validator samples, as field dictionaries.
    private func sampleWorkspace(titled title: String) throws -> [String: SwiftValue] {
        let context = CustomSidebarValidator.defaultDataContext
        let workspaces = try #require(SwiftValue.arrayElements(context["workspaces"]))
        let match = workspaces.lazy.compactMap { SwiftValue.objectFields($0) }.first { $0["title"] == .string(title) }
        return try #require(match, "The sample context has no workspace titled \(title)")
    }

    @Test("the sample data context carries the render builder's shapes and optionality")
    func sampleContextMatchesRenderBuilderShapes() throws {
        // The populated sample: its workspace-level optionals are present with
        // the type CustomSidebarDataContextBuilder emits, never a placeholder string.
        let populated = try sampleWorkspace(titled: "Sample Workspace")
        let pr = try #require(SwiftValue.objectFields(populated["pr"]),
                              "pr must be an object like the builder's pullRequestValues, not a placeholder string (#7944)")
        #expect(pr["number"] == .int(5812))
        #expect(pr["label"] == .string("PR 5812"))
        let progress = try #require(SwiftValue.objectFields(populated["progress"]),
                                    "progress must be an object with a numeric value, not a placeholder string (#7944)")
        #expect(progress["value"] == .double(0.42))
        let remote = try #require(SwiftValue.objectFields(populated["remote"]),
                                   "remote must be an object, not a placeholder string (#7944)")
        #expect(remote["target"] == .string("aws-m4pro-1"))
        #expect(remote["connected"] == .bool(true))
        #expect(populated["latestAt"] == .int(1_779_999_400))
        #expect(pr["branch"] == .string("main"))
        #expect(populated["prs"] == .array([.object(pr)]))
        #expect(populated["status"] == .string("working"))

        // clock is the builder's object, its fields read from one instant.
        let clock = try #require(SwiftValue.objectFields(CustomSidebarValidator.defaultDataContext["clock"]))
        let epoch = 1_780_000_000
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = utc.dateComponents([.hour, .minute, .second, .weekday],
                                       from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        let hour = try #require(parts.hour), minute = try #require(parts.minute)
        let second = try #require(parts.second), weekday = try #require(parts.weekday)
        #expect(clock == [
            "time": .string(String(format: "%02d:%02d:%02d", hour, minute, second)),
            "hour": .int(hour),
            "minute": .int(minute),
            "second": .int(second),
            "weekday": .int(weekday),
            "epoch": .int(epoch),
        ])

        // The quiet sample: optionals the builder omits when absent are absent
        // here too, so the omitted-optional path is reachable in validation.
        let quiet = try sampleWorkspace(titled: "Quiet Workspace")
        for absent in ["branch", "dirty", "description", "color", "pr", "prs", "progress",
                       "latestMessage", "latestPrompt", "latestAt", "remote"] {
            #expect(quiet[absent] == nil, "\(absent) should be omitted like the builder omits it (#7944)")
        }

        // The linked sample: the builder adds branch only when a pull request has
        // one, so its pr (also prs[0]) has none.
        let linked = try sampleWorkspace(titled: "Linked Workspace")
        let linkedPR = try #require(SwiftValue.objectFields(linked["pr"]))
        #expect(linkedPR["number"] == .int(5790))
        #expect(linkedPR["branch"] == nil, "a pull request without a branch omits it like the builder (#7944)")
        #expect(linked["prs"] == .array([.object(linkedPR)]))
    }

    @Test("a sidebar reading pr, pr.branch and progress draws its data rows against the sample context")
    func dataRowsDrawAgainstTheSampleContext() throws {
        let node = try #require(SwiftViewInterpreter().evaluate(
            """
            VStack {
              ForEach(workspaces) { w in
                if w.pr != nil {
                  Text(w.pr.label)
                }
                if w.progress != nil {
                  Text(w.progress.label)
                }
                if w.pr == nil {
                  Text("no pr")
                }
                if w.pr.branch != nil {
                  Text(w.pr.branch)
                }
                if w.pr != nil {
                  if w.pr.branch == nil {
                    Text("no branch")
                  }
                }
              }
            }
            """,
            state: CustomSidebarValidator.defaultDataContext
        ))
        let drawn = Self.texts(in: node)
        #expect(drawn.contains("PR 5812"))
        #expect(drawn.contains("Running tests"))
        #expect(drawn.contains("no pr"))
        #expect(drawn.contains("main"))
        #expect(drawn.filter { $0 == "no branch" }.count == 1)
    }

    /// Every string drawn under `node`, in draw order.
    private static func texts(in node: RenderNode) -> [String] {
        var out: [String] = []
        if let text = node.text { out.append(text) }
        out += node.children.flatMap(texts(in:))
        return out
    }
}

/// Test-only projections over ``SwiftValue`` payloads.
private extension SwiftValue {
    static func arrayElements(_ value: SwiftValue?) -> [SwiftValue]? {
        if case .array(let items)? = value { return items }
        return nil
    }

    static func objectFields(_ value: SwiftValue?) -> [String: SwiftValue]? {
        if case .object(let fields)? = value { return fields }
        return nil
    }
}
