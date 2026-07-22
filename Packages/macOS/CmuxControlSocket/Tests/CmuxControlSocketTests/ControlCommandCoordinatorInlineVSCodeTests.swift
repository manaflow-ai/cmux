import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator inline VS Code")
struct ControlCommandCoordinatorInlineVSCodeTests {
    @Test func openValidatesDirectoryBeforeCrossingTheAppSeam() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let missing = try #require(coordinator.handle(request(params: [:])))
        guard case .err(let missingCode, _, _) = missing else {
            Issue.record("expected missing-path error")
            return
        }
        #expect(missingCode == "invalid_params")

        let absentPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        let absent = try #require(coordinator.handle(request(params: ["path": .string(absentPath)])))
        guard case .err(let absentCode, _, _) = absent else {
            Issue.record("expected not-found error")
            return
        }
        #expect(absentCode == "not_found")
        #expect(context.inlineVSCodeCall == nil)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vscode-file-\(UUID().uuidString)", isDirectory: false)
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fileResult = try #require(coordinator.handle(request(params: ["path": .string(fileURL.path)])))
        guard case .err(let fileCode, _, _) = fileResult else {
            Issue.record("expected non-directory error")
            return
        }
        #expect(fileCode == "invalid_params")
        #expect(context.inlineVSCodeCall == nil)
    }

    @Test func openForwardsAnAbsoluteDirectoryAndReturnsAcceptedRoute() throws {
        let context = FakeCommandPaletteControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vscode-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let windowID = UUID()
        let workspaceID = UUID()
        context.inlineVSCodeResolution = .accepted(windowID: windowID, workspaceID: workspaceID)

        let result = try #require(coordinator.handle(request(params: [
            "path": .string(directoryURL.path),
            "workspace_id": .string(workspaceID.uuidString),
        ])))

        #expect(context.inlineVSCodeCall?.directoryPath == directoryURL.path)
        #expect(context.inlineVSCodeCall?.routing.workspaceID == workspaceID)
        guard case .ok(.object(let payload)) = result else {
            Issue.record("expected vscode.open payload")
            return
        }
        #expect(payload["accepted"] == .bool(true))
        #expect(payload["window_id"] == .string(windowID.uuidString))
        #expect(payload["workspace_id"] == .string(workspaceID.uuidString))
        #expect(payload["path"] == .string(directoryURL.path))
    }

    private func request(params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "vscode.open", params: params)
    }
}
