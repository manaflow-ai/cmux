import Foundation

/// Why a Cloud start refused its folder on this Mac, before anything was copied: each has its own
/// code, and the page its own words (webviews `cloudStartProgress.ts` `cloudRefusalText`).
public nonisolated enum AgentPaneCloudFolderRefusal: Error, Equatable {
    /// Not a folder on this Mac (gone, or a file).
    case missing
    /// The home folder or a folder above it.
    case homeOrAbove
    /// A credential folder under home, or a folder that holds one: its `~/` spelling.
    case secret(String)

    /// Home's folders of keys and credentials, relative to home, that a Cloud copy never takes, nor a
    /// folder holding one (`~/.config` holds gcloud's, `~/Library` Keychains). cmux-tui's
    /// `link/access_cli.rs` `SECRET_FOLDERS` keeps the like list for a shared folder's files, and
    /// `link/sync_cli/skips.rs` `CREDENTIAL_FOLDERS` is this same list, left out of a copy at any depth (its
    /// test reads this one: keep it one string per name, in `[...]`). Never all of `~/Library`:
    /// iCloud Drive and the cloud-storage folders (Dropbox, Google Drive) hold projects there. gh's OAuth
    /// tokens are in `~/.config/gh/hosts.yml`, Cargo's registry token in `~/.cargo/credentials.toml`.
    public static let secretFolders = [".ssh", ".aws", ".gnupg", ".config/gcloud", ".config/gh", ".kube", ".docker", ".secrets", ".azure",
                                       ".cargo", ".gem", ".terraform.d", ".password-store", "Library/Keychains"]

    /// The first of ``secretFolders`` that `folder` (canonical) is in or holds, by path components; nil
    /// for none. Reads no disk: a credential folder need not exist to be refused.
    public static func secretFolder(of folder: String, home: String) -> String? {
        secretFolders.first { relative in
            // By case too: this Mac's disk does not tell `~/.SSH` from `~/.ssh`.
            let secret = (home as NSString).appendingPathComponent(relative).lowercased(), folder = folder.lowercased()
            return AcpmuxPathPolicy.contains(root: secret, path: folder) || AcpmuxPathPolicy.contains(root: folder, path: secret)
        }
    }

    /// The first of ``secretFolders`` that `folder` (canonical) is in anywhere on this Mac (`/Users/me/backup/.aws`), by
    /// path components and in any case: its copy would hold only the files inside, whose own names say nothing. cmux-tui's
    /// `skips.rs` `credential_folder_of` is the same rule. Reads no disk.
    public static func nestedSecretFolder(of folder: String) -> String? {
        let names = folder.lowercased().split(separator: "/")
        return secretFolders.first { relative in
            let parts = relative.lowercased().split(separator: "/")
            return names.count >= parts.count && (0...(names.count - parts.count)).contains { Array(names[$0..<($0 + parts.count)]) == parts }
        }
    }

    /// The refusal of `folder` (absolute, `.` and `..` resolved) read from its words alone, before the disk is read
    /// (``AgentPaneCloudStart/checkedFolder(_:home:)`` reads it later): home, above it or the disk's root, or a
    /// credential folder; nil for none.
    public static func written(_ folder: String, home: String) -> Self? {
        let home = (home as NSString).standardizingPath
        if AgentHome.isHomeOrAbove(folder, home: home) { return .homeOrAbove }
        return secretFolder(of: folder, home: home).map { .secret("~/" + $0) } ?? nestedSecretFolder(of: folder).map { .secret($0) }
    }

    public var code: String {
        switch self {
        case .missing: "cloud_folder_missing"
        case .homeOrAbove: "cloud_folder_home"
        case .secret: "cloud_folder_secret"
        }
    }

    /// The reply: the secret's message is the folder's `~/` spelling, which the page's words name.
    public var reply: [String: Any] {
        if case .secret(let folder) = self { return AgentPaneReply.failure(code: code, message: folder) }
        return AgentPaneReply.failure(code: code, message: code)
    }
}

extension AgentPaneCloudStart {
    /// The folder a Cloud start copies for a chat in `cwd` on this Mac, checked: `cwd` canonical, and the
    /// Git working copy that holds it (``uploadRoot(of:)``, the folder copied) and that copy's git folders
    /// (history, refs), each a real folder that is never home or above it and never is nor holds a
    /// credential folder (``copyableFolder(_:home:)``). The composer's Send (``AgentPaneHandOff``) and
    /// `cmux cloud start-session --from-folder` (the App's `CloudStartSession`) both copy only what this
    /// answers. Reads the disk off the main thread.
    public nonisolated static func checkedFolder(_ cwd: String, home: String?) async -> Result<(folder: String, root: String), AgentPaneCloudFolderRefusal> {
        let folder: String
        switch await copyableFolder(cwd, home: home) {
        case .success(let checked): folder = checked
        case .failure(let refusal): return .failure(refusal)
        }
        let root = await Task.detached(priority: .userInitiated) { AgentPaneCloudStart.uploadRoot(of: folder) }.value
        if root != folder {
            switch await copyableFolder(root, home: home) {
            case .success(let checked) where checked == root: break
            case .success: return .failure(.missing)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        let gitFolders = await Task.detached(priority: .userInitiated) { AgentPaneCloudStart.gitFolders(of: root) }.value
        for gitFolder in gitFolders {
            if case .failure(let refusal) = await copyableFolder(gitFolder, home: home) { return .failure(refusal) }
        }
        return .success((folder, root))
    }

    /// Whether a new chat's first Send in Cloud needs the person's gesture: a Send needs none (#45429; Leo, 2026-11-17:
    /// "go remove this"), except where the gesture is the person's pick of a folder to copy off this Mac, one that is not
    /// the tab's own (``isTabsOwn(_:roots:home:)``). No folder: the App uses the tab's. Reads the disk off the main thread.
    @MainActor static func picksFolder(_ start: AgentPaneCloudStart, transport: AgentPaneTransport) async -> Bool {
        guard let upload = start.uploadRoot else { return false }
        let roots = transport.roots()
        let home = transport.homeFolder
        return await Task.detached(priority: .userInitiated) { !isTabsOwn(upload, roots: roots, home: home) }.value
    }

    /// Whether every one of `root`'s ``gitFolders(of:)`` is `root` or below it (by canonical path
    /// components): a folder copied with no pane check behind it (a tab's own folder) never uploads
    /// a repository a `.git` file or `commondir` names elsewhere. Reads the disk.
    public nonisolated static func gitFoldersAreInside(_ root: String) -> Bool {
        let base = ((AcpmuxPathPolicy.canonical(root) ?? root) as NSString).pathComponents
        return gitFolders(of: root).allSatisfy { folder in
            let parts = ((AcpmuxPathPolicy.canonical(folder) ?? (folder as NSString).standardizingPath) as NSString).pathComponents
            return parts.count >= base.count && Array(parts.prefix(base.count)) == base
        }
    }

    /// Whether a Cloud start's upload root (``checkedFolder(_:home:)``'s `root`, canonical) is the tab's own, so its
    /// Send needs no gesture: under one of `roots` that is not home or above it (a terminal at `~` lists `~`; the same
    /// rule as ``AcpmuxPathPolicy``), with every git folder it copies inside it (a linked worktree's are not).
    /// Reads the disk: call it off the main thread.
    nonisolated static func isTabsOwn(_ upload: String, roots: [String], home: String?) -> Bool {
        let userHome = home.flatMap(AcpmuxPathPolicy.canonical)
        let homeOrAbove = { (path: String) in path == "/" || userHome.map { AcpmuxPathPolicy.contains(root: path, path: $0) } == true }
        let own = roots.compactMap(AcpmuxPathPolicy.canonical).filter { !homeOrAbove($0) }
        return own.contains { AcpmuxPathPolicy.contains(root: $0, path: upload) } && gitFoldersAreInside(upload)
    }

    /// `path` canonical when it is a real folder that is not the home folder or above it, and neither
    /// is nor holds one of home's credential folders (``AgentPaneCloudFolderRefusal/secretFolders``);
    /// the refusal otherwise. A Cloud start copies such a folder only on the Send's own gesture (`held`),
    /// or on a person's or script's `cloud start-session --from-folder`.
    nonisolated static func copyableFolder(_ path: String, home: String?) async -> Result<String, AgentPaneCloudFolderRefusal> {
        await Task.detached(priority: .userInitiated) { () -> Result<String, AgentPaneCloudFolderRefusal> in
            guard let folder = AcpmuxPathPolicy.canonical(path), AcpmuxPathPolicy.isDirectory(folder) else { return .failure(.missing) }
            // No home given: this Mac's own, so the home and credential checks never lapse.
            let home = home ?? NSHomeDirectory()
            let canonicalHome: String? = AcpmuxPathPolicy.canonical(home) ?? (home as NSString).standardizingPath
            guard !AgentHome.isHomeOrAbove(folder, home: canonicalHome) else { return .failure(.homeOrAbove) }
            if let canonicalHome, let secret = AgentPaneCloudFolderRefusal.secretFolder(of: folder, home: canonicalHome) {
                return .failure(.secret("~/" + secret))
            }
            if let secret = AgentPaneCloudFolderRefusal.nestedSecretFolder(of: folder) { return .failure(.secret(secret)) }
            return .success(folder)
        }.value
    }
}
