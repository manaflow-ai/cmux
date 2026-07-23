import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator inline VS Code")
struct ControlCommandCoordinatorInlineVSCodeTests {
    @Test func openIsWorkerOnlyAndValidatesDirectoryBeforeCrossingTheAppSeam() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(
            context: context,
            inlineVSCodeFileSystem: ControlInlineVSCodeFileSystem(
                currentDirectoryPath: { "/fixture" },
                inspectPath: { path in
                    (exists: path == "/fixture/file", isDirectory: false)
                }
            )
        )

        #expect(coordinator.handle(request(params: [:])) == nil)

        let missing = try #require(workerResult(coordinator, context: context, params: [:]))
        guard case .err(let missingCode, let missingMessage, _) = missing else {
            Issue.record("expected missing-path error")
            return
        }
        #expect(missingCode == "invalid_params")
        #expect(missingMessage == "missing inline path")

        let whitespaceOnly = try #require(workerResult(
            coordinator,
            context: context,
            params: ["path": .string("  \n\t  ")]
        ))
        guard case .err(let whitespaceCode, _, _) = whitespaceOnly else {
            Issue.record("expected whitespace-only path error")
            return
        }
        #expect(whitespaceCode == "invalid_params")

        let absent = try #require(workerResult(
            coordinator,
            context: context,
            params: ["path": .string("absent")]
        ))
        guard case .err(let absentCode, let absentMessage, _) = absent else {
            Issue.record("expected not-found error")
            return
        }
        #expect(absentCode == "not_found")
        #expect(absentMessage == "inline directory not found")
        #expect(context.inlineVSCodeCall == nil)

        let fileResult = try #require(workerResult(
            coordinator,
            context: context,
            params: ["path": .string("file")]
        ))
        guard case .err(let fileCode, let fileMessage, _) = fileResult else {
            Issue.record("expected non-directory error")
            return
        }
        #expect(fileCode == "invalid_params")
        #expect(fileMessage == "inline path is not a directory")
        #expect(context.inlineVSCodeCall == nil)
    }

    @Test func openPreservesPathWhitespaceAndReturnsExplicitQueuedStatus() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("  cmux-vscode-dir-\(UUID().uuidString)  ", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let windowID = UUID()
        let workspaceID = UUID()
        context.inlineVSCodeResolution = .accepted(windowID: windowID, workspaceID: workspaceID)

        let result = try #require(workerResult(coordinator, context: context, params: [
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

    @Test func unresolvedExplicitSelectorsFailClosedBeforeCrossingTheAppSeam() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let directoryURL = FileManager.default.temporaryDirectory

        let selectors = [
            (key: "window_id", value: "window:999999"),
            (key: "group_id", value: "workspace_group:999999"),
            (key: "workspace_id", value: "workspace:999999"),
            (key: "surface_id", value: "surface:999999"),
            (key: "pane_id", value: "pane:999999"),
        ]
        for selector in selectors {
            let result = try #require(workerResult(coordinator, context: context, params: [
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

    @Test func appSideQueueFailureDoesNotReturnAcceptedPayload() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        context.inlineVSCodeResolution = .openFailed

        let result = try #require(workerResult(
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
    ) -> ControlCallResult? {
        coordinator.handleSocketWorkerV2(request(params: params), context: context)
    }

    private func request(params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "vscode.open", params: params)
    }
}
