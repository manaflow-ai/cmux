import Darwin
public import CmuxNextCompat
public import Foundation
import os

/// One-time moves of the items NEXT kept loose in classic cmux's
/// `~/Library/Application Support/cmux` to the same names under `cmux-next`
/// (cmuxterm-hq goals/next-store-out-of-classic.md), beside ``StateFolderMove``,
/// which runs it at launch before anything reads them.
///
/// Only items worth keeping move: the server fix ledger and unsaved recovery
/// drafts (folders, renamed once with a symlink left for an older build, as
/// ``StateFolderMove`` does) and a kept-name build's Debug Settings file
/// (``moveDebugTunables(to:tag:bundleID:)``, when Debug Settings starts).
/// Caches and regenerated files just start in the new place.
public struct ClassicFolderItemsMove: Sendable {
    /// Folders only NEXT writes in classic's `cmux`: the fix ledger, recovery drafts, and the folders
    /// ``BuildStatePaths`` and the Rust defaults now keep in `cmux-next` (every workspace's agent home, chat
    /// attachments, cmux-remote's identity, the browser host's cookie backups, cmux-tasks' store, `cmux app
    /// try`'s kept builds and the try on now, the codex app-server bundle). Each keeps a link at its old path:
    /// chats and agent configs name agent-home and Chat Uploads paths, and a CLI from before the move still
    /// finds its try.
    static let folders = ["server-fix-ledger", "recovery", "agent-home", "Chat Uploads", "remote", "browser-host", "tasks",
                          "app-try", "codex-app-server"]

    /// Files only NEXT writes in classic's `~/.config/cmux`, moved to ``BuildStatePaths/configDirectory``
    /// (`~/.config/cmux-next`) once, with no link: the settings file and what lives beside it, the
    /// Cloud secrets and keys indexes (names only), the host budget, `cmux vm`'s config and the web-dev
    /// overlay file. Classic's own files there (`cmux.json`, `settings.json`, `dock.json`, `sidebars`,
    /// `env`, ...) are never touched.
    static let configFiles = ["cmux-next.json", "keybindings.json", "cloud-secrets.json", "keys.json", "host-budget.json",
                              "vm.json", "web-dev.json"]
    /// Folders only NEXT writes in classic's `~/.config/cmux`, moved the same way. The GitHub feed's
    /// worktrees keep a link, since git records each worktree's path.
    static let configFolders = ["automations", "customize", "commands", "themes", "agent-pane", "diff", "harnesses",
                                "screen-host", "github-worktrees"]
    /// Files classic cmux may also read in `~/.config/cmux` (cmux-tui's config): copied once, never moved.
    static let configCopies = ["cmux-tui.json"]
    /// The one item classic cmux installs in the shared `~/.config/cmux/skills` (its Cloud skill): every
    /// other entry there is the person's NEXT skill and moves to `~/.config/cmux-next/skills`.
    static let classicSkills: Set<String> = ["cmux-cloud.md"]

    let applicationSupport: URL
    private static let logger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")

    public init(applicationSupport: URL = DaemonLauncher.applicationSupportDirectory()) {
        self.applicationSupport = applicationSupport
    }

    /// Moves each of ``folders``, once. Cheap when there is nothing to move: one `lstat` each.
    @discardableResult
    public func run() -> [StateFolderMove.Outcome] {
        Self.folders.map { name in
            let (old, new) = paths(name)
            var info = stat()
            guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .nothing }
            return log(StateFolderMove.move(old: old, new: new), old: old)
        }
    }

    /// Items only NEXT writes in classic's `cmux/<bundle id>`: Cloud's (Swift `CloudPaths`, Rust
    /// `cmux_cloud_environment::Resolver`) and the SSH link's state.
    static let bundleItems = ["cloud-next", "cloud-environment.json", "client-config", "ssh-next"]

    /// Moves NEXT's items in classic's `cmux/<bundle id>` to the bundle's own folder under `cmux-next`
    /// (``NextSupport/bundleFolder(bundleID:)``), once each, leaving a symlink at each old path for a
    /// daemon or CLI from before the move: ``bundleItems`` and the namespaced sign-in stores (a folder
    /// with a `credentials.json`). The folder itself and the `credentials.json` directly in it stay:
    /// classic cmux of the same bundle id (NIGHTLY, `com.cmuxterm.app.nightly`) keeps its file-fallback
    /// sign-in there, and NEXT shares that one store with it on purpose (one Keychain service, one session).
    /// Rust's resolver moves its own two items the same way, for a CLI that runs before the app.
    @discardableResult
    public func moveBundleItems(bundleID: String?) -> [String: StateFolderMove.Outcome] {
        let support = NextSupport(applicationSupport: applicationSupport)
        let old = support.classicBundleFolder(bundleID: bundleID), new = support.bundleFolder(bundleID: bundleID)
        var info = stat()
        guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [:] }
        let children = (try? FileManager.checked.contentsOfDirectory(atPath: old.path)) ?? []
        let stores = children.filter { name in
            !Self.bundleItems.contains(name) && Self.isFolder(old.appending(path: name))
                && FileManager.checked.fileExists(atPath: old.appending(path: "\(name)/credentials.json").path)
        }
        var outcomes: [String: StateFolderMove.Outcome] = [:]
        for name in Self.bundleItems + stores.sorted() {
            let from = old.appending(path: name), to = new.appending(path: name)
            guard lstat(from.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: outcomes[name] = log(StateFolderMove.move(old: from, new: to), old: from)
            case S_IFREG: outcomes[name] = log(Self.moveLinkingBack(old: from, new: to), old: from)
            default: outcomes[name] = .nothing // the link an earlier move left
            }
        }
        return outcomes
    }

    /// Moves the bundle's Computer Use runtime folder (its helper's agent token and state) from classic's
    /// `cmux/cmux-cua/runtime/<scope>` to ``NextSupport/computerUseRuntime(bundleID:)``, once, leaving a
    /// symlink for a helper an older app started. Other scopes' folders and the shared `helper` copies stay.
    @discardableResult
    public func moveComputerUseRuntime(bundleID: String) -> StateFolderMove.Outcome {
        let support = NextSupport(applicationSupport: applicationSupport)
        let old = support.classicComputerUseRuntime(bundleID: bundleID)
        guard Self.isFolder(old) else { return .nothing }
        return log(StateFolderMove.move(old: old, new: support.computerUseRuntime(bundleID: bundleID)), old: old)
    }

    /// Moves the bundle's Computer Use helper copies (`next-<scope>`, `next-v2-<scope>`) from classic's
    /// `cmux/cmux-cua/helper` to `cmux-next/cmux-cua/helper`, once each, with no link left: an older build
    /// refuses a staging folder behind a link and would never stage again, while with none it stages a new
    /// copy. Classic's own copies and other scopes' stay.
    @discardableResult
    public func moveComputerUseCopies(bundleID: String) -> [StateFolderMove.Outcome] {
        let support = NextSupport(applicationSupport: applicationSupport)
        let scope = NextSupport.computerUseScope(bundleID)
        return ["next-\(scope)", "next-v2-\(scope)"].map { name in
            let old = applicationSupport.appending(path: "cmux/cmux-cua/helper/\(name)", directoryHint: .isDirectory)
            guard Self.isFolder(old) else { return .nothing }
            let new = support.folder.appending(path: "cmux-cua/helper/\(name)", directoryHint: .isDirectory)
            return log(StateFolderMove.move(old: old, new: new, link: false), old: old)
        }
    }

    /// Moves NEXT's items in classic's `~/.config/cmux` (`paths.classicConfigDirectory`) to its own
    /// ``BuildStatePaths/configDirectory``, once each: ``configFiles``, ``configFolders``, a copy of each of
    /// ``configCopies`` and every skill but ``classicSkills``. Never over anything at the new path. Nothing for a
    /// build that keeps its own folder (a DEV build, a state root): it never used classic's. Run at launch
    /// before anything reads the settings file (`CmuxConfigFile.prepareLaunchFile` would otherwise make
    /// a new one). Cheap when there is nothing to move: one `lstat` each.
    @discardableResult
    public static func moveConfigItems(paths: BuildStatePaths) -> [String: StateFolderMove.Outcome] {
        guard !paths.ownsState else { return [:] }
        let old = paths.classicConfigDirectory, new = paths.configDirectory
        guard isFolder(old), old.standardizedFileURL != new.standardizedFileURL else { return [:] }
        var outcomes: [String: StateFolderMove.Outcome] = [:]
        var info = stat()
        for name in configFiles {
            let from = old.appending(path: name)
            guard lstat(from.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            outcomes[name] = logged(moveExclusive(old: from, new: new.appending(path: name)), old: from)
        }
        for name in configFolders {
            let from = old.appending(path: name, directoryHint: .isDirectory)
            guard isFolder(from) else { continue }
            let to = new.appending(path: name, directoryHint: .isDirectory)
            outcomes[name] = logged(StateFolderMove.move(old: from, new: to, link: name == "github-worktrees"), old: from)
        }
        for name in configCopies {
            let from = old.appending(path: name), to = new.appending(path: name)
            guard lstat(from.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, lstat(to.path, &info) != 0 else { continue }
            do {
                try FileManager.checked.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.checked.copyItem(at: from, to: to)
                outcomes[name] = .moved
            } catch {
                outcomes[name] = logged(.kept("copy: \(error.localizedDescription)"), old: from)
            }
        }
        let skills = old.appending(path: "skills", directoryHint: .isDirectory)
        if isFolder(skills) {
            for name in ((try? FileManager.checked.contentsOfDirectory(atPath: skills.path)) ?? []).sorted()
            where !classicSkills.contains(name) {
                let from = skills.appending(path: name), to = new.appending(path: "skills/\(name)")
                guard lstat(from.path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: outcomes["skills/\(name)"] = logged(StateFolderMove.move(old: from, new: to, link: false), old: from)
                case S_IFREG: outcomes["skills/\(name)"] = logged(moveExclusive(old: from, new: to), old: from)
                default: continue
                }
            }
        }
        return outcomes
    }

    /// Renames the file `old` to `new`, never over anything at `new`, with no link left.
    static func moveExclusive(old: URL, new: URL) -> StateFolderMove.Outcome {
        do {
            try FileManager.checked.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .kept("cannot make \(new.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        // RENAME_EXCL: refuses (EEXIST) when anything is already at `new`.
        guard renamex_np(old.path, new.path, UInt32(bitPattern: RENAME_EXCL)) == 0 else {
            return .kept("rename: \(String(cString: strerror(errno)))")
        }
        return .moved
    }

    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Renames the file `old` to `new`, never over anything at `new`, and leaves a symlink at `old`.
    static func moveLinkingBack(old: URL, new: URL) -> StateFolderMove.Outcome {
        do {
            try FileManager.checked.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .kept("cannot make \(new.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        // RENAME_EXCL: refuses (EEXIST) when anything is already at `new`.
        guard renamex_np(old.path, new.path, UInt32(bitPattern: RENAME_EXCL)) == 0 else {
            return .kept("rename: \(String(cString: strerror(errno)))")
        }
        _ = symlink(new.path, old.path)
        return .moved
    }

    /// Moves the file at `relativePath` below classic's `cmux` to the same path below `cmux-next`,
    /// once: only a regular file moves, and never over anything already at the new path.
    @discardableResult
    public func moveFile(_ relativePath: String) -> StateFolderMove.Outcome {
        let (old, new) = paths(relativePath)
        var info = stat()
        guard lstat(old.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .nothing }
        return log(Self.moveExclusive(old: old, new: new), old: old)
    }

    /// A build that keeps its app names keeps its Debug Settings file here, relative to `cmux-next`
    /// (and to classic's `cmux` before): `<tag or channel>/debug-tunables.json`.
    public static func debugTunables(tag: String?, bundleID: String?) -> String {
        let folder = tag ?? (bundleID.map { $0.hasPrefix(BuildIdentity.nightlyBundleID) ? "nightly" : "dev" } ?? "dev")
        return "\(folder)/debug-tunables.json"
    }

    /// Moves a kept-name build's Debug Settings file (``debugTunables(tag:bundleID:)``) once,
    /// when `url` (the file the build reads) is its place under `cmux-next`; nothing for an override or a per-key build.
    @discardableResult
    public func moveDebugTunables(to url: URL, tag: String?, bundleID: String?) -> StateFolderMove.Outcome {
        let file = Self.debugTunables(tag: tag, bundleID: bundleID)
        return url.path.hasSuffix("/cmux-next/\(file)") ? moveFile(file) : .nothing
    }

    private func paths(_ relativePath: String) -> (old: URL, new: URL) {
        (applicationSupport.appending(path: "cmux/\(relativePath)"),
         DaemonLauncher.nextSupport(applicationSupport).appending(path: relativePath))
    }

    private func log(_ outcome: StateFolderMove.Outcome, old: URL) -> StateFolderMove.Outcome {
        Self.logged(outcome, old: old)
    }

    private static func logged(_ outcome: StateFolderMove.Outcome, old: URL) -> StateFolderMove.Outcome {
        if case .kept(let why) = outcome {
            Self.logger.error("\(old.path, privacy: .public) stays in classic's folder: \(why, privacy: .public)")
        } else {
            Self.logger.notice("\(old.path, privacy: .public) moved to cmux-next")
        }
        return outcome
    }
}
