import Foundation

/// Names a new machine's first workspace for what it is instead of the
/// daemon's counter ("workspace-1").
///
/// cmux-tui creates a machine's first workspace before any client connects,
/// so it can only number it. Every creation entry point (`cmux vm new`, the
/// New Cloud Machine sheet, the Cloud menu, ⌘⇧Y, the Machines tree) ends in
/// one `SurfaceCatalog.bindCloudWorkspace`, which asks this policy whether
/// the adopted name should be replaced. `cmux vm clone` and `cmux vm dev`
/// already name their workspace for the repository, so those names are never
/// counter names and pass through untouched.
///
/// A machine created without opening it (the router's pool machines behind
/// `cmux vm run`, `vm agent` and `vm clone`) never reaches that bind, and a
/// clone then adds its repository workspace beside the untouched counter one,
/// after which the sole-workspace rule can never name it. `vm clone` therefore
/// asks ``adoptableInitialWorkspaceID(_:)`` on a machine it just provisioned and
/// names that first workspace for the repository instead. This file is compiled
/// into the CLI as well so both sides share one definition of a counter name.
struct CloudInitialWorkspaceName: Equatable {
    /// The cmux-tui workspace this decision is about.
    var remoteWorkspaceID: String
    /// Its current name, as the daemon reports it.
    var remoteName: String?
    /// Every workspace the machine reports, or nil while it has not reported.
    var machineWorkspaceIDs: [String]?
    /// The workspace's presented working directory (`~/work/todo-app`), when known.
    var workingDirectory: String?
    /// The machine's friendly label (`brave-otter`).
    var machineLabel: String?
    /// Raw identifiers that must never be shown as a name (the VM id and its
    /// provider-prefixed form).
    var machineRawIDs: [String]

    /// The replacement name, or nil when the daemon name should stand.
    ///
    /// Only a machine's sole workspace is renamed: a second `workspace-2`
    /// beside `brave-otter` is a deliberate, distinct workspace and renaming
    /// it too would give one machine two identical names.
    var replacement: String? {
        guard let remoteName, Self.isDaemonCounterName(remoteName),
              let ids = machineWorkspaceIDs,
              ids.allSatisfy({ $0 == remoteWorkspaceID }) else { return nil }
        if let project = Self.projectName(fromWorkingDirectory: workingDirectory) { return project }
        guard let label = machineLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
              !machineRawIDs.contains(label), !Self.isDaemonCounterName(label) else { return nil }
        return label
    }

    /// The workspace a named request on a brand-new machine should take over
    /// rather than add a second one beside it: the machine's only workspace,
    /// still carrying the daemon's counter name. Nil when the machine has any
    /// other workspace or the first one was already named, which means
    /// someone chose that name. Callers ask only about a machine they created
    /// moments ago, so the counter workspace holds nothing but an idle shell.
    static func adoptableInitialWorkspaceID(_ workspaces: [(id: String, name: String)]) -> String? {
        guard workspaces.count == 1, let only = workspaces.first,
              !only.id.isEmpty, isDaemonCounterName(only.name) else { return nil }
        return only.id
    }

    /// `workspace-<digits>`, the only shape cmux-tui's `default_workspace_name`
    /// produces (see `CloudTreeNodeBuilder.predictedDefaultWorkspaceName`).
    static func isDaemonCounterName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("workspace-") else { return false }
        let suffix = trimmed.dropFirst("workspace-".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isASCIIDigit)
    }

    /// The project folder a workspace sits in, or nil when it sits in a home
    /// or root directory, which name the user rather than the work.
    static func projectName(fromWorkingDirectory directory: String?) -> String? {
        guard var path = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if path.hasPrefix("~") {
            // `~` or `~user` alone is a home directory.
            guard components.count >= 2 else { return nil }
        } else if path.hasPrefix("/") {
            if components.isEmpty { return nil }
            let homeParents: Set<String> = ["home", "Users"]
            if components.count == 1, components[0] == "root" || homeParents.contains(components[0]) { return nil }
            if components.count == 2, homeParents.contains(components[0]) { return nil }
        } else {
            return nil
        }
        guard let last = components.last, !last.hasPrefix("~"), last != ".",
              !genericFolderNames.contains(last.lowercased()) else { return nil }
        return last
    }

    /// Container folders that say where projects live, not which one this is.
    private static let genericFolderNames: Set<String> = [
        "work", "workspace", "workspaces", "src", "code", "projects", "repos", "tmp", "var", "opt", "srv",
    ]
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
