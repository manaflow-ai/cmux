import Foundation

/// The POSIX `sh` scripts an agent move runs on either endpoint.
///
/// Every path is passed in explicitly (never `$HOME`), so the same script runs
/// against the local home, a remote home, or a test directory.
struct AgentMoveScripts {
    private let q = AgentMoveShellQuoting()

    /// Prints `AM_HOME=<physical path of $HOME>` and whether it is the same directory
    /// as `localHome`. The physical path is what Claude records as the cwd and what
    /// `git rev-parse --show-toplevel` prints, so path mapping uses it.
    func probeHome(localHome: String) -> String {
        """
        printf 'AM_HOME=%s\\n' "$(cd "$HOME" && pwd -P)"
        if [ "$HOME" -ef \(q.quote(localHome)) ]; then echo AM_SAME=yes; else echo AM_SAME=no; fi
        """
    }

    /// Prints `AM_LIVE` when a Claude process for `sessionID` runs on this machine.
    ///
    /// Claude writes `<config>/sessions/<pid>.json` naming the session for each
    /// running process; a resume also carries the id on its command line.
    func liveness(claudeDirectory: String, sessionID: String) -> String {
        // The pgrep pattern never matches this script's own command line: the
        // only `--resume` here is followed by `[`, not a space or `=`.
        """
        for f in \(q.quote(claudeDirectory))/sessions/*.json; do
          [ -f "$f" ] || continue
          grep -q \(q.quote(sessionID)) "$f" || continue
          pid=$(basename "$f" .json)
          if kill -0 "$pid" 2>/dev/null; then echo AM_LIVE; exit 0; fi
        done
        if pgrep -f -- \(q.quote("claude.*--resume[ =]\(sessionID)")) >/dev/null 2>&1; then echo AM_LIVE; fi
        exit 0
        """
    }

    /// Prints the first transcript path for `sessionID` under `claudeDirectory/projects`.
    func findTranscript(claudeDirectory: String, sessionID: String) -> String {
        """
        for f in \(q.quote(claudeDirectory))/projects/*/\(q.quote(sessionID + ".jsonl")); do
          if [ -f "$f" ]; then printf '%s\\n' "$f"; exit 0; fi
        done
        exit 0
        """
    }

    /// Prints the last `"cwd":"..."` field of a transcript: the directory of the latest turn.
    func transcriptWorkingDirectory(transcript: String) -> String {
        "grep -o '\"cwd\":\"[^\"]*\"' \(q.quote(transcript)) | tail -n 1"
    }

    /// Exits 0 when `path` is a directory.
    func isDirectory(_ path: String) -> String {
        "test -d \(q.quote(path))"
    }

    /// Prints the byte size of `path`, or nothing when it does not exist.
    func fileSize(_ path: String) -> String {
        "if [ -f \(q.quote(path)) ]; then wc -c < \(q.quote(path)) | tr -d ' '; fi"
    }

    /// Prints the checksum of the first `bytes` bytes of `path`.
    func prefixChecksum(_ path: String, bytes: Int) -> String {
        "head -c \(bytes) \(q.quote(path)) | cksum"
    }

    /// Prints the checksum of `path`.
    func checksum(_ path: String) -> String {
        "cksum < \(q.quote(path))"
    }

    /// Creates directories.
    func makeDirectories(_ paths: [String]) -> String {
        "mkdir -p " + paths.map(q.quote).joined(separator: " ")
    }

    /// Prints the top of the git checkout holding `path`, or nothing.
    func checkoutTop(_ path: String) -> String {
        "git -C \(q.quote(path)) rev-parse --show-toplevel 2>/dev/null || true"
    }

    /// Exits 0 when `path` is the top of a git checkout (not a folder inside another repository).
    func isCheckout(_ path: String) -> String {
        """
        top=$(git -C \(q.quote(path)) rev-parse --show-toplevel 2>/dev/null) || exit 1
        [ "$(cd "$top" && pwd -P)" = "$(cd \(q.quote(path)) && pwd -P)" ]
        """
    }

    /// Prints the physical path of the checkout's common git directory.
    func commonGitDirectory(checkout: String) -> String {
        "cd \(q.quote(checkout)) && cd \"$(git rev-parse --git-common-dir)\" && pwd -P"
    }

    /// Exits 0 when `gitDirectory` is a repository.
    func isRepository(gitDirectory: String) -> String {
        "git --git-dir=\(q.quote(gitDirectory)) rev-parse >/dev/null 2>&1"
    }

    /// Adds a detached worktree at `path`.
    func addWorktree(gitDirectory: String, path: String) -> String {
        "git --git-dir=\(q.quote(gitDirectory)) worktree add --detach \(q.quote(path)) 2>&1"
    }

    /// Prints the tree of the working tree (tracked, modified, deleted and
    /// untracked non-ignored files) without touching the real index or any ref.
    func workingTreeTree(checkout: String) -> String {
        """
        set -e
        cd \(q.quote(checkout))
        idx=$(mktemp); rm -f "$idx"; trap 'rm -f "$idx"' EXIT
        # -p keeps the index mtime: a fresh one would hide same-size edits made
        # in the second the index was written (git's racy-clean check).
        cp -p "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || true
        GIT_INDEX_FILE="$idx" git add -A >/dev/null
        GIT_INDEX_FILE="$idx" git write-tree
        """
    }

    /// Prints `HEAD^{tree}`, a blank line, then the tree of `ref` (empty when missing).
    func headAndRefTrees(checkout: String, ref: String) -> String {
        """
        cd \(q.quote(checkout)) || exit 1
        git rev-parse 'HEAD^{tree}' || exit 1
        echo
        git rev-parse -q --verify \(q.quote(ref + "^{tree}")) || true
        """
    }

    /// Records the working tree as a commit whose parent is HEAD at `ref` (the
    /// outgoing ref, promoted only after the destination applied it), then prints
    /// the snapshot, HEAD, and the current branch (empty when detached).
    func snapshot(checkout: String, ref: String, sessionID: String) -> String {
        """
        set -e
        cd \(q.quote(checkout))
        idx=$(mktemp); rm -f "$idx"; trap 'rm -f "$idx"' EXIT
        # -p keeps the index mtime: a fresh one would hide same-size edits made
        # in the second the index was written (git's racy-clean check).
        cp -p "$(git rev-parse --git-path index)" "$idx" 2>/dev/null || true
        export GIT_INDEX_FILE="$idx"
        git add -A >/dev/null
        tree=$(git write-tree)
        snap=$(printf 'agent-move snapshot %s\\n' \(q.quote(sessionID)) | git -c user.name=cmux -c user.email=agent-move@cmux.invalid commit-tree "$tree" -p HEAD)
        git update-ref \(q.quote(ref)) "$snap"
        unset GIT_INDEX_FILE
        echo "AM_SNAP=$snap"
        echo "AM_HEAD=$(git rev-parse HEAD)"
        echo "AM_BRANCH=$(git symbolic-ref -q --short HEAD || true)"
        """
    }

    /// Marks the source's working tree as the snapshot the destination now holds.
    func promoteSnapshot(checkout: String, outgoingRef: String, ref: String, snapshot: String) -> String {
        """
        cd \(q.quote(checkout)) || exit 1
        git update-ref \(q.quote(ref)) \(q.quote(snapshot)) && git update-ref -d \(q.quote(outgoingRef))
        """
    }

    /// Moves the destination checkout to the source HEAD (the same branch when
    /// that is safe) and its working tree to the snapshot. `read-tree -u --reset`
    /// removes files the snapshot no longer has, so deletions and renames carry.
    /// Prints `AM_DIVERGED` and exits 3 when the branch has commits HEAD lacks.
    func apply(
        checkout: String,
        head: String,
        branch: String?,
        snapshot: String,
        ref: String,
        incomingRef: String,
        resetFrom: String?
    ) -> String {
        let resetLine = resetFrom.map { "git read-tree -u --reset \(q.quote($0))" } ?? ":"
        return """
        set -e
        cd \(q.quote(checkout))
        sha=\(q.quote(head))
        snap=\(q.quote(snapshot))
        branch=\(q.quote(branch ?? ""))
        if [ -n "$branch" ] && git rev-parse -q --verify "refs/heads/$branch" >/dev/null && ! git merge-base --is-ancestor "refs/heads/$branch" "$sha"; then
          echo AM_DIVERGED
          exit 3
        fi
        \(resetLine)
        if [ -n "$branch" ]; then
          here=$(pwd -P)
          elsewhere=$(git worktree list --porcelain | awk -v p="$here" -v b="refs/heads/$branch" '/^worktree /{w=substr($0,10)} /^branch /{if (substr($0,8)==b && w!=p) print w}')
          if [ -z "$elsewhere" ]; then
            git update-ref "refs/heads/$branch" "$sha"
            git symbolic-ref HEAD "refs/heads/$branch"
          else
            git update-ref --no-deref HEAD "$sha"
          fi
        else
          git update-ref --no-deref HEAD "$sha"
        fi
        git read-tree -u --reset "$snap"
        git reset -q
        git update-ref \(q.quote(ref)) "$snap"
        git update-ref -d \(q.quote(incomingRef))
        """
    }
}
