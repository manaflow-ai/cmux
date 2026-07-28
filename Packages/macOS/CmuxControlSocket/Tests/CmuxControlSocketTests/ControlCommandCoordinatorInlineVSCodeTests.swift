import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator inline VS Code")
struct ControlCommandCoordinatorInlineVSCodeTests {
    @Test func missingContextDoesNotUsePackageFallbackStrings() {
        let coordinator = ControlCommandCoordinator()

        #expect(coordinator.handleSocketWorkerV2(request(params: [:]), context: nil) == nil)
    }

    @Test func openIsAsyncAndValidatesDirectoryBeforeQueueing() async throws {
        let context = FakeCommandPaletteControlCommandContext()
        context.inlineVSCodeResolutionForPath = { path in
            path == "/fixture/file" ? .notDirectory : .directoryNotFound
        }
        let coordinator = ControlCommandCoordinator(
            context: context,
            inlineVSCodeFileSystem: ControlInlineVSCodeFileSystem(
                currentDirectoryPath: { "/fixture" }
            )
        )

        #expect(coordinator.handle(request(params: [:])) == nil)

        let missing = try #require(await workerResult(coordinator, context: context, params: [:]))
        guard case .err(let missingCode, let missingMessage, _) = missing else {
            Issue.record("expected missing-path error")
            return
        }
        #expect(missingCode == "invalid_params")
        #expect(missingMessage == "missing inline path")

        let whitespaceOnly = try #require(await workerResult(
            coordinator,
            context: context,
            params: ["path": .string("  \n\t  ")]
        ))
        guard case .err(let whitespaceCode, _, _) = whitespaceOnly else {
            Issue.record("expected whitespace-only path error")
            return
        }
        #expect(whitespaceCode == "invalid_params")

        let absent = try #require(await workerResult(
            coordinator,
            context: context,
            params: [
                "path": .string("absent"),
                "cwd": .string("/fixture"),
            ]
        ))
        guard case .err(let absentCode, let absentMessage, _) = absent else {
            Issue.record("expected not-found error")
            return
        }
        #expect(absentCode == "not_found")
        #expect(absentMessage == "inline directory not found")
        #expect(context.inlineVSCodeCall?.directoryPath == "/fixture/absent")

        let callerRelative = try #require(await workerResult(
            coordinator,
            context: context,
            params: ["path": .string("absent")]
        ))
        guard case .err(let callerRelativeCode, _, _) = callerRelative else {
            Issue.record("expected caller-relative not-found error")
            return
        }
        #expect(callerRelativeCode == "not_found")
        #expect(context.inlineVSCodeCall?.directoryPath == "/fixture/absent")

        let fileResult = try #require(await workerResult(
            coordinator,
            context: context,
            params: [
                "path": .string("file"),
                "cwd": .string("/fixture"),
            ]
        ))
        guard case .err(let fileCode, let fileMessage, _) = fileResult else {
            Issue.record("expected non-directory error")
            return
        }
        #expect(fileCode == "invalid_params")
        #expect(fileMessage == "inline path is not a directory")
        #expect(context.inlineVSCodeCall?.directoryPath == "/fixture/file")
    }

    @Test func relativePathRejectsExplicitInvalidCallerDirectory() async throws {
        let invalidCallerDirectories: [(label: String, value: JSONValue)] = [
            ("relative string", .string("fixture")),
            ("empty string", .string("")),
            ("boolean", .bool(true)),
            ("integer", .int(1)),
            ("double", .double(1.5)),
            ("array", .array([])),
            ("object", .object([:])),
        ]

        for invalidCallerDirectory in invalidCallerDirectories {
            let context = FakeCommandPaletteControlCommandContext()
            context.inlineVSCodeResolution = .accepted(windowID: UUID(), workspaceID: UUID())
            let coordinator = ControlCommandCoordinator(
                context: context,
                inlineVSCodeFileSystem: ControlInlineVSCodeFileSystem(
                    currentDirectoryPath: { "/fallback" }
                )
            )

            let result = try #require(await workerResult(
                coordinator,
                context: context,
                params: [
                    "path": .string("project"),
                    "cwd": invalidCallerDirectory.value,
                ]
            ))

            guard case .err(let code, let message, _) = result else {
                Issue.record("expected invalid cwd error for \(invalidCallerDirectory.label)")
                continue
            }
            #expect(code == "invalid_params")
            #expect(message == "inline cwd must be absolute")
            #expect(context.inlineVSCodeCall == nil)
        }
    }

    @Test func relativePathWithNullCallerDirectoryUsesProcessDirectory() async throws {
        let context = FakeCommandPaletteControlCommandContext()
        context.inlineVSCodeResolution = .directoryNotFound
        let coordinator = ControlCommandCoordinator(
            context: context,
            inlineVSCodeFileSystem: ControlInlineVSCodeFileSystem(
                currentDirectoryPath: { "/fallback" }
            )
        )

        let result = try #require(await workerResult(
            coordinator,
            context: context,
            params: [
                "path": .string("project"),
                "cwd": .null,
            ]
        ))

        guard case .err(let code, _, _) = result else {
            Issue.record("expected missing-directory error")
            return
        }
        #expect(code == "not_found")
        #expect(context.inlineVSCodeCall?.directoryPath == "/fallback/project")
    }

    @Test func openPreservesPathWhitespaceAndReturnsExplicitQueuedStatus() async throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("  cmux-vscode-dir-\(UUID().uuidString)  ", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let windowID = UUID()
        let workspaceID = UUID()
        context.inlineVSCodeResolution = .accepted(windowID: windowID, workspaceID: workspaceID)

        let result = try #require(await workerResult(coordinator, context: context, params: [
            "path": .string(directoryURL.path),
            "workspace_id": .string(workspaceID.uuidString),
        ]))

        #expect(context.inlineVSCodeCall?.directoryPath == directoryURL.path)
        #expect(context.inlineVSCodeCall?.routing.workspaceID == workspaceID)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected vscode.open payload")
            return
        }
        #expect(payload["accepted"] == .bool(true))
        #expect(payload["status"] == .string("queued"))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["window_ref"] == .string("window:1"))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["workspace_ref"] == .string("workspace:1"))
        #expect(payload["path"] == .string(directoryURL.path))
    }

    @Test func unresolvedExplicitSelectorsFailClosedBeforeCrossingTheAppSeam() async throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let directoryURL = FileManager.default.temporaryDirectory

        let selectors = [
            (key: "window_id", value: "window:999999"),
            (key: "group_id", value: "workspace_group:999999"),
            (key: "workspace_id", value: "workspace:999999"),
            (key: "surface_id", value: "surface:999999"),
            (key: "terminal_id", value: "surface:999999"),
            (key: "tab_id", value: "surface:999999"),
            (key: "pane_id", value: "pane:999999"),
        ]
        for selector in selectors {
            let result = try #require(await workerResult(coordinator, context: context, params: [
                "path": .string(directoryURL.path),
                selector.key: .string(selector.value),
            ]))

            guard case .err(let code, let message, _) = result else {
                Issue.record("expected unresolved-selector error for \(selector.key)")
                continue
            }
            #expect(code == "not_found")
            #expect(message == "inline workspace not found")
        }
        #expect(context.inlineVSCodeCall == nil)
    }

    @Test func unresolvedOrConflictingSurfaceAliasesFailClosedBeforeCrossingTheAppSeam() async throws {
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()
        let cases: [[String: JSONValue]] = [
            [
                "surface_id": .string("surface:missing"),
                "terminal_id": .string(firstSurfaceID.uuidString),
            ],
            [
                "surface_id": .string(firstSurfaceID.uuidString),
                "terminal_id": .string("surface:missing"),
            ],
            [
                "surface_id": .string(firstSurfaceID.uuidString),
                "tab_id": .string(secondSurfaceID.uuidString),
            ],
        ]

        for aliases in cases {
            let context = FakeCommandPaletteControlCommandContext()
            context.inlineVSCodeResolution = .accepted(windowID: UUID(), workspaceID: UUID())
            let coordinator = ControlCommandCoordinator(context: context)
            var params = aliases
            params["path"] = .string(FileManager.default.temporaryDirectory.path)

            let result = try #require(await workerResult(coordinator, context: context, params: params))

            guard case .err(let code, let message, _) = result else {
                Issue.record("expected invalid surface-alias error for \(aliases)")
                continue
            }
            #expect(code == "not_found")
            #expect(message == "inline workspace not found")
            #expect(context.inlineVSCodeCall == nil)
        }
    }

    @Test func matchingSurfaceAliasesReachTheAppSeamAsOneTarget() async throws {
        let context = FakeCommandPaletteControlCommandContext()
        let surfaceID = UUID()
        context.inlineVSCodeResolution = .accepted(windowID: UUID(), workspaceID: UUID())
        let coordinator = ControlCommandCoordinator(context: context)
        let surfaceRef = coordinator.ensureRef(kind: .surface, uuid: surfaceID)
        let tabRef = surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")

        let result = try #require(await workerResult(coordinator, context: context, params: [
            "path": .string(FileManager.default.temporaryDirectory.path),
            "surface_id": .string(surfaceID.uuidString),
            "terminal_id": .string(surfaceRef),
            "tab_id": .string(tabRef),
        ]))

        guard case .ok = result else {
            Issue.record("expected matching surface aliases to be accepted")
            return
        }
        #expect(context.inlineVSCodeCall?.routing.surfaceID == surfaceID)
    }

    @Test func appSideQueueFailureDoesNotReturnAcceptedPayload() async throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        context.inlineVSCodeResolution = .openFailed

        let result = try #require(await workerResult(
            coordinator,
            context: context,
            params: ["path": .string(FileManager.default.temporaryDirectory.path)]
        ))

        guard case .err(let code, let message, _) = result else {
            Issue.record("expected queue failure")
            return
        }
        #expect(code == "internal_error")
        #expect(message == "inline open failed")
    }

    private func workerResult(
        _ coordinator: ControlCommandCoordinator,
        context: FakeCommandPaletteControlCommandContext,
        params: [String: JSONValue]
    ) async -> ControlCallResult? {
        await coordinator.handleAsync(request(params: params))
    }

    private func request(params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "vscode.open", params: params)
    }
}
