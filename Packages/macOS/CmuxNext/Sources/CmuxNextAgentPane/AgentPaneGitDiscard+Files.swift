import Foundation

/// Whole-file Revert (``AgentPaneGitDiscard``), in this order so a failure part way leaves as little
/// half done as it can, and says which files it did not revert:
/// 1. Read what git knows of each path: the index entry, the HEAD entry (Uncommitted), and whether
///    it is intent-to-add (`git add -N`, an empty placeholder in the index). A submodule refuses the
///    whole request before anything changes.
/// 2. Uncommitted: files in HEAD go back to it in one `git restore --source=HEAD --staged --worktree`.
/// 3. Files new in the index (Uncommitted: not in HEAD; Unstaged: intent-to-add) leave it.
///    Restoring an intent-to-add file from the index would write its empty placeholder.
/// 4. Unstaged: the other tracked files get the index's content back.
/// 5. The files that left the index, and those git lists as untracked, go to the Trash. Every one is
///    tried; the ones that did not move are named.
extension AgentPaneGitDiscard {
    static func revertFiles(_ paths: [String], scope: AgentPaneGitScope, in repository: String, trash mover: Trashing) async -> String? {
        let git = Self.git(repository)
        let all = pathspecs(paths)
        let indexRead = await entries(git + ["ls-files", "-z", "--stage", "--"] + all, modeFirst: true)
        var headRead = Listing.success([:])
        if scope == .uncommitted {
            headRead = await entries(git + ["ls-tree", "-r", "-z", "--full-tree", "HEAD", "--"] + all, modeFirst: true)
        }
        let intentRead = await entries(git + ["diff", "--no-ext-diff", "--name-only", "-z", "--diff-filter=A", "--"] + all, modeFirst: false)
        guard case .success(let index) = indexRead else { return indexRead.message }
        guard case .success(let head) = headRead else { return headRead.message }
        guard case .success(let intent) = intentRead else { return intentRead.message }
        if paths.contains(where: { index[$0] == "160000" || head[$0] == "160000" }) { return submoduleMessage }

        var done: Set<String> = []
        func left() -> [String] { paths.filter { !done.contains($0) } }
        if scope == .uncommitted {
            let back = paths.filter { head[$0] != nil }
            if !back.isEmpty {
                let restore = git + ["restore", "--source=HEAD", "--staged", "--worktree", "--"] + pathspecs(back)
                if let message = await AgentPaneGitProcess.run(restore, timeout: timeout) { return message }
                done.formUnion(back)
            }
        }
        let newInIndex = paths.filter { index[$0] != nil && (scope == .uncommitted ? head[$0] == nil : intent[$0] != nil) }
        if !newInIndex.isEmpty,
           let message = await AgentPaneGitProcess.run(git + ["restore", "--staged", "--"] + pathspecs(newInIndex), timeout: timeout) {
            return partial(message, left())
        }
        if scope == .unstaged {
            let tracked = paths.filter { index[$0] != nil && intent[$0] == nil }
            if !tracked.isEmpty {
                if let message = await AgentPaneGitProcess.run(git + ["restore", "--worktree", "--"] + pathspecs(tracked), timeout: timeout) {
                    return partial(message, left())
                }
                done.formUnion(tracked)
            }
        }
        let untrackedRead = await entries(git + ["ls-files", "-z", "--others", "--exclude-standard", "--"] + all, modeFirst: false)
        guard case .success(let untracked) = untrackedRead else { return partial(untrackedRead.message ?? "", left()) }
        var failure: String?
        var notMoved: [String] = []
        for path in paths where !done.contains(path) && (untracked[path] != nil || newInIndex.contains(path)) {
            if let message = trash(path, in: repository, using: mover) {
                failure = failure ?? message
                notMoved.append(path)
            }
        }
        if let failure { return partial(failure, notMoved) }
        return nil
    }

    /// `message`, then the files left as they were.
    static func partial(_ message: String, _ notReverted: [String]) -> String {
        notReverted.isEmpty ? message : message + " " + String(format: notRevertedMessage, notReverted.joined(separator: ", "))
    }

    /// A `-z` listing by path: `ls-files --stage` and `ls-tree` rows (`<mode> <object> ...\t<path>`,
    /// `modeFirst`) give each path's mode; a names-only listing gives each path an empty value.
    private static func entries(_ arguments: [String], modeFirst: Bool) async -> Listing {
        let outcome = await AgentPaneGitProcess.output(arguments, timeout: timeout)
        guard outcome.status == 0 else { return .failure(outcome.message) }
        var listing: [String: String] = [:]
        for row in outcome.text.split(separator: "\0") {
            guard modeFirst else {
                listing[String(row)] = ""
                continue
            }
            guard let tab = row.firstIndex(of: "\t") else { continue }
            listing[String(row[row.index(after: tab)...])] = String(row[..<tab].prefix { $0 != " " })
        }
        return .success(listing)
    }

    private enum Listing {
        case success([String: String])
        case failure(String)

        var message: String? {
            if case .failure(let message) = self { return message }
            return nil
        }
    }

    /// Moves `path` to the Trash when its folder, links resolved, is inside `repository` (the file
    /// itself may be a link: the link moves, not what it names). A file already gone is not an error.
    static func trash(_ path: String, in repository: String, using mover: Trashing) -> String? {
        let url = URL(fileURLWithPath: repository).appending(path: path)
        guard let folder = AcpmuxPathPolicy.canonical(url.deletingLastPathComponent().path),
              AcpmuxPathPolicy.contains(root: repository, path: folder) else { return outsideMessage }
        let item = URL(fileURLWithPath: folder).appending(path: url.lastPathComponent)
        var status = stat()
        guard lstat(item.path, &status) == 0 else { return nil }
        do {
            try mover(item)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
