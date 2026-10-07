import Foundation

extension AgentPaneModel {
    /// Reads directory names only after a native user gesture. Browsing never grants roots to
    /// the agent transport. Home is a read-only browser root and is never added to transport
    /// roots, chosen folders, or granted roots.
    func listProjectDirectory(_ path: String) async -> [String: Any] {
        guard transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        let home = transport.homeFolder ?? NSHomeDirectory()
        let roots = [home] + roots().filter { !isHomeOrAbove($0) }
        // task-owner: this request awaits the one filesystem read; no background lifetime.
        let result = await Task.detached {
            AgentPaneDirectoryListing.list(path: path, roots: roots, home: home)
        }.value
        switch result {
        case .success(let listing):
            return AgentPaneReply.success([
                "path": listing.path,
                "parent": listing.parent.map { $0 as Any } ?? NSNull(),
                "home": listing.home,
                "directories": listing.directories,
            ])
        case .failure:
            return AgentPaneReply.failure(code: "project.directory_unavailable", message: String(localized: "agentPane.shell.folderMissing", defaultValue: "Folder not found", bundle: .module))
        }
    }
}
