import Foundation

extension TerminalController {
    /// Returns the selected workspace's working-tree patch for the native iOS diff shell.
    @MainActor
    func v2MobileDiffLoad(params: [String: Any]) async -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager),
              let directory = workspace.resolvedWorkingDirectory() else {
            return .err(code: "not_found", message: "Workspace directory not found", data: nil)
        }
        do {
            let document = try await mobileWorkingTreeDiffCoordinator.load(
                key: "\(workspace.id.uuidString):\(URL(fileURLWithPath: directory).standardizedFileURL.path)",
                directory: directory,
                title: workspace.title
            )
            return .ok(document.rpcValue)
        } catch let error as MobileWorkingTreeDiffLoadError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(code: "internal_error", message: "Failed to load workspace diff", data: nil)
        }
    }
}
