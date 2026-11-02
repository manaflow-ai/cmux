import Foundation

extension AgentPaneTransport {
    /// A folder the user picked in the native Open panel (New Tab > Add project > Local folder,
    /// `project.browse`): a root from then on, like Choose Folder…'s pick, so the page's requests
    /// about its project (the folder's own harnesses) pass the folder check, also for a folder the
    /// project scan never lists (cx-nkyvn: one under `~/.cache`). Never the home folder or above
    /// it: that stays the user's answer to the home question (`workspace.useFolder`). Returns `path`.
    func pick(_ path: String) async -> String {
        let homeFolder = homeFolder
        let (picked, home) = await Task.detached {
            (AcpmuxPathPolicy.canonical(path).flatMap { AcpmuxPathPolicy.isDirectory($0) ? $0 : nil },
             homeFolder.flatMap(AcpmuxPathPolicy.canonical))
        }.value
        guard let picked, picked != "/" else { return path }
        if let home, AcpmuxPathPolicy.contains(root: picked, path: home) { return path }
        grant(picked)
        // The native Open panel is an explicit user folder-open action. Record the same choice in
        // acpmux so its harness trust gate does not ask a second time for this folder.
        await trustPicked(picked)
        return path
    }
}
