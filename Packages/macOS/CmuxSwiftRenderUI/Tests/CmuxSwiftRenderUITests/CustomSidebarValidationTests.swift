import CmuxSidebar
import CmuxSwiftRender
import Foundation
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar validation")
struct CustomSidebarValidationTests {
    private let validator = CustomSidebarValidator(
        warningLocale: Locale(identifier: "en")
    )

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

    @Test("default validation data renders like the runtime context builder")
    func defaultValidationDataMatchesRuntimeBuilder() throws {
        let source = """
        VStack {
            Text(clock.time)
            ForEach(workspaces) { workspace in
                Text(workspace.title)
                if let pullRequest = workspace.pr {
                    Text(pullRequest.label)
                }
                if let progress = workspace.progress {
                    ProgressView(value: progress.value, total: 1.0)
                }
                if let branch = workspace.branch {
                    Text(branch)
                }
                if let latestAt = workspace.latestAt {
                    Text("\\(latestAt)")
                }
                if let remote = workspace.remote {
                    Text(remote.target)
                }
            }
        }
        """
        let interpreter = SwiftViewInterpreter()
        let runtimeNode = try #require(interpreter.evaluate(source, state: Self.representativeRuntimeContext))
        let validationNode = try #require(
            interpreter.evaluate(source, state: CustomSidebarValidator.defaultDataContext)
        )

        #expect(validationNode == runtimeNode)
    }

    @Test("warns when a supported root's sample render collapses to empty")
    func warnsAboutEmptyRenderedContainer() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("empty.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                if workspace.unread > 100 {
                    Text(workspace.title)
                }
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(entry.warningMessages == ["Sidebar rendered no visible content."])
    }

    @Test("warns about the status board when referenced optional data has no effect")
    func warnsAboutStatusBoardWithoutOptionalDataCoverage() {
        let fileURL = examplesDirectory().appendingPathComponent("status-board.swift")

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(
            entry.warningMessages
                == [
                    "Sidebar output did not change when its referenced optional workspace data was removed.",
                ]
        )
    }

    @Test("warns when optional-absent sample output collapses to empty")
    func warnsWhenOptionalDataRemovalEmptiesRender() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("branch.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                if let branch = workspace.branch {
                    Text(branch)
                }
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(
            entry.warningMessages
                == [
                    "Sidebar rendered no visible content when optional workspace data was absent.",
                ]
        )
    }

    @Test("sample-dependent optional branches remain non-blocking")
    func acceptsOptionalBranchThatIsFalseForRepresentativeData() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("dirty.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                if workspace.dirty {
                    Image(systemName: "circle.fill")
                }
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.isValid)
        #expect(entry.warningMessages.contains("Sidebar rendered no visible content."))
        #expect(
            entry.warningMessages.contains(
                "Sidebar output did not change when its referenced optional workspace data was removed."
            )
        )
    }

    @Test("value-form color backgrounds and overlays count as visible")
    func acceptsVisibleValueFormDecoration() throws {
        let directory = try temporaryDirectory()
        for modifier in ["background", "overlay"] {
            let fileURL = directory.appendingPathComponent("\(modifier).swift")
            try """
            VStack {}
                .frame(width: 20, height: 20)
                .\(modifier)("#FFFFFF")
            """.write(to: fileURL, atomically: true, encoding: .utf8)

            let entry = validator.validate(fileURL: fileURL)

            #expect(entry.errorMessage == nil)
            #expect(entry.warningMessages.isEmpty)
        }
    }

    @Test("visibility-removing modifiers produce empty-render warnings")
    func warnsAboutFullyTransparentOutput() throws {
        let directory = try temporaryDirectory()
        let sources = [
            "opacity": """
            Text("Hidden")
                .opacity(0)
            """,
            "mask": """
            Text("Hidden")
                .mask {
                    Rectangle()
                        .fill(.clear)
                }
            """,
        ]

        for (name, source) in sources {
            let fileURL = directory.appendingPathComponent("\(name).swift")
            try source.write(to: fileURL, atomically: true, encoding: .utf8)

            let entry = validator.validate(fileURL: fileURL)

            #expect(entry.errorMessage == nil)
            #expect(
                entry.warningMessages == ["Sidebar rendered no visible content."],
                "Expected \(name) to suppress all rendered output"
            )
        }
    }

    @Test("gradient visibility follows resolved renderer stops")
    func validatesResolvedGradientVisibility() throws {
        let directory = try temporaryDirectory()
        let emptyURL = directory.appendingPathComponent("empty-gradient.swift")
        try """
        LinearGradient(colors: [], startPoint: .top, endPoint: .bottom)
            .frame(width: 20, height: 20)
        """.write(to: emptyURL, atomically: true, encoding: .utf8)
        let visibleURL = directory.appendingPathComponent("visible-gradient.swift")
        try """
        LinearGradient(colors: [.red, .blue], startPoint: .top, endPoint: .bottom)
            .frame(width: 20, height: 20)
        """.write(to: visibleURL, atomically: true, encoding: .utf8)

        let emptyEntry = validator.validate(fileURL: emptyURL)
        let visibleEntry = validator.validate(fileURL: visibleURL)

        #expect(
            emptyEntry.warningMessages == ["Sidebar rendered no visible content."]
        )
        #expect(visibleEntry.warningMessages.isEmpty)
    }

    @Test("a visible border around an empty framed container counts as output")
    func acceptsVisibleBorderDecoration() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("border.swift")
        try """
        VStack {}
            .frame(width: 20, height: 20)
            .border(.red, width: 1)
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(entry.warningMessages.isEmpty)
    }

    @Test("mask and context menu children do not count as visible output")
    func ignoresNonDrawingModifierChildren() throws {
        let directory = try temporaryDirectory()
        for modifier in ["mask", "contextMenu"] {
            let fileURL = directory.appendingPathComponent("\(modifier).swift")
            try """
            VStack {}
                .\(modifier) {
                    Text("Hidden child")
                }
            """.write(to: fileURL, atomically: true, encoding: .utf8)

            let entry = validator.validate(fileURL: fileURL)

            #expect(entry.errorMessage == nil)
            #expect(entry.warningMessages == ["Sidebar rendered no visible content."])
        }
    }

    @Test("safe-area inset children count as visible output")
    func acceptsVisibleSafeAreaInset() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("inset.swift")
        try """
        VStack {}
            .safeAreaInset(edge: .top) {
                Text("Inset")
            }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(entry.warningMessages.isEmpty)
    }

    @Test("warns when Gauge has no renderable value")
    func warnsAboutGaugeWithoutValue() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("gauge.swift")
        try """
        Gauge(value: workspaceCount / 0)
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(entry.warningMessages == ["Sidebar rendered no visible content."])
    }

    @Test("validation report counts warning messages")
    func countsWarnings() throws {
        let directory = try temporaryDirectory()
        try """
        VStack {}
        """.write(to: directory.appendingPathComponent("empty.swift"), atomically: true, encoding: .utf8)

        let report = validator.validate(directory: directory)

        #expect(report.validCount == 1)
        #expect(report.errorCount == 0)
        #expect(report.warningCount == 1)
        #expect(
            report.entries.first?.warningMessages
                == ["Sidebar rendered no visible content."]
        )
    }

    @Test("does not attribute nested tab fields to their workspace")
    func acceptsNestedMemberSharingOptionalWorkspaceFieldName() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("tabs.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                ForEach(workspace.tabs) { tab in
                    Text(tab.branch)
                }
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(entry.warningMessages.isEmpty)
    }

    @Test("does not attribute reads from an unchanged sparse workspace")
    func ignoresOptionalReadsFromUnchangedWorkspace() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("sparse.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                if workspace.title == "notes" {
                    Text(workspace.branch)
                }
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(entry.warningMessages == ["Sidebar rendered no visible content."])
    }

    @Test("warns when only a PR array renders and optional PR data is absent")
    func warnsWhenPullRequestArrayRemovalEmptiesRender() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("prs.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                ForEach(workspace.prs) { pullRequest in
                    Text(pullRequest.label)
                }
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(
            entry.warningMessages
                == [
                    "Sidebar rendered no visible content when optional workspace data was absent.",
                ]
        )
    }

    @Test("changed-field detection includes stable keys with empty values")
    func tracksChangedStableWorkspaceFields() {
        let richFields: [String: SwiftValue] = [
            "prs": .array([.object(["number": .int(412)])]),
        ]
        let comparisonFields: [String: SwiftValue] = [
            "prs": .array([]),
        ]

        #expect(
            changedWorkspaceFieldNames(
                between: richFields,
                and: comparisonFields
            ) == ["prs"]
        )
    }

    @Test("ignored modifiers cannot masquerade as optional-data output")
    func warnsWhenOptionalDataOnlyChangesIgnoredModifier() throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("ignored.swift")
        try """
        VStack {
            ForEach(workspaces) { workspace in
                Text("Fixed")
                    .custom(workspace.branch)
            }
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let entry = validator.validate(fileURL: fileURL)

        #expect(entry.errorMessage == nil)
        #expect(
            entry.warningMessages
                == [
                    "Sidebar output did not change when its referenced optional workspace data was removed.",
                ]
        )
    }

    @Test("deep validation helpers walk rendered output iteratively")
    func validatesDeepOutputWithoutCallerStackRecursion() {
        // This exceeds the nesting known to overflow recursive interpreter
        // walks on a caller-sized stack. Construct it iteratively so this test
        // isolates the two post-evaluation validation traversals.
        let depth = 600
        var visibleTree = RenderNode(kind: .text, text: "Deep")
        var matchingTree = RenderNode(kind: .text, text: "Deep")
        var emptyTree = RenderNode(kind: .group)
        for _ in 0..<depth {
            visibleTree = RenderNode(kind: .vstack, children: [visibleTree])
            matchingTree = RenderNode(kind: .vstack, children: [matchingTree])
            emptyTree = RenderNode(kind: .vstack, children: [emptyTree])
        }

        #expect(visibleTree.containsVisibleContent)
        #expect(!emptyTree.containsVisibleContent)
        #expect(visibleTree.hasSameValidationOutput(as: matchingTree))
        #expect(!visibleTree.hasSameValidationOutput(as: emptyTree))
    }

    @Test("warning strings resolve through package localizations")
    func warningStringsResolveThroughPackageLocalizations() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")

        #expect(
            localizedEmptySidebarRenderWarning(locale: english)
                == "Sidebar rendered no visible content."
        )
        #expect(
            localizedEmptySidebarRenderWithoutOptionalDataWarning(locale: english)
                == "Sidebar rendered no visible content when optional workspace data was absent."
        )
        #expect(
            localizedMissingOptionalDataCoverageWarning(locale: english)
                == "Sidebar output did not change when its referenced optional workspace data was removed."
        )
        #expect(
            localizedEmptySidebarRenderWarning(locale: japanese)
                == "サイドバーに表示可能な内容がレンダリングされませんでした。"
        )
        #expect(
            localizedEmptySidebarRenderWithoutOptionalDataWarning(locale: japanese)
                == "オプションのワークスペースデータがない場合、サイドバーに表示可能な内容がレンダリングされませんでした。"
        )
        #expect(
            localizedMissingOptionalDataCoverageWarning(locale: japanese)
                == "参照されているオプションのワークスペースデータを削除しても、サイドバーの出力が変化しませんでした。"
        )
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

    private static let representativeRuntimeContext: [String: SwiftValue] = {
        let selectedId = UUID(uuidString: "00000000-0000-0000-0000-000000000412")!
        let sparseId = UUID(uuidString: "00000000-0000-0000-0000-000000000413")!
        let surfaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000414")!
        let pullRequest: SwiftValue = .object([
            "number": .int(412),
            "label": .string("PR #412"),
            "url": .string("https://github.com/manaflow-ai/cmux/pull/412"),
            "status": .string("open"),
            "stale": .bool(false),
            "branch": .string("fix/checkout"),
        ])
        let richWorkspace = CustomSidebarWorkspaceSnapshot(
            id: selectedId,
            title: "checkout-flow",
            isSelected: true,
            isPinned: false,
            index: 0,
            directory: "/Users/cmux/checkout-flow",
            listeningPorts: [3000],
            unreadCount: 3,
            surfaces: [
                CustomSidebarSurfaceSnapshot(
                    panelId: surfaceId,
                    title: "Tests",
                    isFocused: true,
                    isPinned: false,
                    directory: "/Users/cmux/checkout-flow",
                    gitBranch: "fix/checkout",
                    gitIsDirty: false,
                    listeningPorts: [3000]
                ),
            ],
            surfaceCount: 1,
            customDescription: "Checkout work",
            customColor: "#7AA2F7",
            gitBranch: "fix/checkout",
            gitIsDirty: false,
            pullRequestValues: [pullRequest],
            progress: .init(value: 0.41, label: "Tests running"),
            latestConversationMessage: "Waiting for review",
            latestSubmittedMessage: "Finish checkout coverage",
            latestSubmittedAt: Date(timeIntervalSince1970: 1_779_999_400),
            remote: .init(target: "aws-m4pro-1", stateRawValue: "connected", isConnected: true)
        )
        let sparseWorkspace = CustomSidebarWorkspaceSnapshot(
            id: sparseId,
            title: "notes",
            isSelected: false,
            isPinned: false,
            index: 1,
            directory: "/Users/cmux/notes",
            listeningPorts: [],
            unreadCount: 0,
            surfaces: [],
            surfaceCount: 0,
            customDescription: nil,
            customColor: nil,
            gitBranch: nil,
            gitIsDirty: false,
            pullRequestValues: [],
            progress: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil,
            remote: nil
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return CustomSidebarDataContextBuilder(calendar: calendar).dataContext(
            for: CustomSidebarContextSnapshot(
                workspaces: [richWorkspace, sparseWorkspace],
                selectedWorkspaceId: selectedId,
                selectedWorkspaceTitle: richWorkspace.title,
                totalUnreadCount: 3,
                now: Date(timeIntervalSince1970: 1_780_000_000)
            )
        )
    }()

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
