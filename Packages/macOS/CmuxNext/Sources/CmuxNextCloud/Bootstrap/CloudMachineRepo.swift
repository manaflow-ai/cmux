public import Foundation

/// `cloud new-machine --repo OWNER/NAME[@REF]`: the GitHub repository the new machine clones into
/// `~/work/NAME` before its bootstrap script runs. Parsed and checked here, on the Mac; the
/// machine gets `repo.json` (a record, no secret) and the `repo` step with these values in it.
///
/// No token is ever written to the machine. The step uses the first GitHub path the machine
/// already has: the lane broker's `lane-gh-credential` when it is git's helper (lane VMs), else
/// `cmux github credential` when the machine's Cloud agent socket is there (it mints a short
/// repo-scoped token in memory), else no credential at all (public repositories). Every other
/// helper, a stored gh login's included, is reset for its git commands. A private repository
/// with none of these ends `needs_github`.
///
/// Prior art: #21028's `cmux vm clone` spec parser and its idempotent clone-or-fetch.
public struct CloudMachineRepo: Equatable, Sendable {
    public var owner: String
    public var name: String
    /// A branch, tag or commit; nil keeps the remote's default branch.
    public var ref: String?

    public init(owner: String, name: String, ref: String? = nil) {
        self.owner = owner
        self.name = name
        self.ref = ref
    }

    public enum Invalid: Error, Equatable {
        /// Not a GitHub repository in one of the accepted forms.
        case unrecognized
        /// A token or password in the URL: it would land in the machine's git config.
        case credentialsInURL
        case invalidRef
    }

    public var url: String { "https://github.com/\(owner)/\(name).git" }
    /// Relative to the machine user's home.
    public var directory: String { "work/\(name)" }
    public var spec: String { "\(owner)/\(name)" + (ref.map { "@\($0)" } ?? "") }

    /// `owner/name`, `https://github.com/owner/name[.git][/tree/BRANCH]`, `git@github.com:owner/name.git`
    /// or `ssh://git@github.com/owner/name.git`, each with an optional `@REF` at the end (it wins
    /// over a `/tree/BRANCH`).
    public static func parse(_ raw: String) throws -> CloudMachineRepo {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var ref: String?
        // `@REF` is the first `@` in the path: a URL's or scp form's login comes before it.
        let path: String.Index? = if let scheme = text.range(of: "://") {
            text[scheme.upperBound...].firstIndex(of: "/")
        } else {
            text.firstIndex(of: ":") ?? text.startIndex
        }
        if let path, let at = text[path...].firstIndex(of: "@") {
            ref = String(text[text.index(after: at)...])
            text = String(text[..<at])
        }
        let segments: [String]
        if let scheme = text.range(of: "://") {
            guard ["https", "http", "ssh"].contains(text[..<scheme.lowerBound].lowercased()),
                  let components = URLComponents(string: text), let host = components.host else { throw Invalid.unrecognized }
            if components.password != nil { throw Invalid.credentialsInURL }
            if let user = components.user, !(user == "git" && components.scheme?.lowercased() == "ssh") { throw Invalid.credentialsInURL }
            guard ["github.com", "www.github.com"].contains(host.lowercased()), components.port == nil,
                  components.query == nil, components.fragment == nil else { throw Invalid.unrecognized }
            segments = components.path.split(separator: "/").map(String.init)
        } else if let colon = text.firstIndex(of: ":") {
            // git's scp-like form; only GitHub's own login is not a credential.
            let authority = text[..<colon]
            guard authority.lowercased().hasSuffix("github.com") else { throw Invalid.unrecognized }
            guard authority.lowercased() == "git@github.com" else { throw authority.contains("@") ? Invalid.credentialsInURL : Invalid.unrecognized }
            segments = text[text.index(after: colon)...].split(separator: "/").map(String.init)
        } else {
            segments = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segments.count == 2 else { throw Invalid.unrecognized }
        }
        guard segments.count == 2 || (segments.count >= 4 && segments[2] == "tree") else { throw Invalid.unrecognized }
        let owner = segments[0], name = segments[1].lowercased().hasSuffix(".git") ? String(segments[1].dropLast(4)) : segments[1]
        guard isPathComponent(owner), isPathComponent(name) else { throw Invalid.unrecognized }
        if ref == nil, segments.count >= 4 { ref = segments[3...].joined(separator: "/") }
        if let ref { guard isRef(ref) else { throw Invalid.invalidRef } }
        return CloudMachineRepo(owner: owner, name: name, ref: ref)
    }

    /// Letters, digits, `.`, `_`, `-`; not starting with `.` or `-` (it becomes a directory).
    static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && !value.hasPrefix(".") && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// A safe subset of `git check-ref-format --branch`: letters, digits, `.`, `_`, `-`, `/`, so it
    /// needs no quoting in shell or JSON. `HEAD` names no branch (leave the ref out for the default);
    /// no part starts with `.` or ends with `.lock`.
    static func isRef(_ value: String) -> Bool {
        !value.isEmpty && value != "HEAD" && !value.hasPrefix("HEAD/")
            && value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") } && value.count <= 255 && !value.hasPrefix("-") && !value.hasPrefix("/") && !value.hasSuffix("/")
            && !value.hasSuffix(".") && !value.hasSuffix(".lock") && !value.contains("..") && !value.contains("//")
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)) }
    }

    /// `repo.json`: what the machine was asked to clone, for a person or a tool reading the machine.
    public var record: Data {
        var object: [String: String] = ["url": url, "owner": owner, "name": name, "dir": "~/" + directory]
        if let ref { object["ref"] = ref }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The step's exit code when the repository needs GitHub access the machine does not have.
    public static let needsGitHubExit = 3

    /// The `repo` step (`~/.cmux/bootstrap/repo`). Every value in it passed ``parse(_:)``'s
    /// checks, so none needs quoting. It writes `repo-status.json` beside itself, which the runner
    /// puts in `status.json` as `repo`. Each GitHub path the machine has is tried in order, and
    /// every git command of the step (a checkout of a blobless clone fetches too) runs with the
    /// other helpers, askpass and prompts off.
    public var step: String {
        let quoted = { (text: String) in "'\(text)'" }
        return #"""
            #!/bin/sh
            # cmux machine bootstrap: the repo step (cmux cloud new-machine --repo). It stores no secret
            # anywhere: it uses the GitHub access the machine already has, or none.
            set -u
            d=$(cd "$(dirname "$0")" && pwd)
            url=\#(quoted(url)); ref=\#(quoted(ref ?? "")); dir="$HOME/\#(directory)"
            cred=none; helper=""; status=failed; sha=""; why=""; fresh=""
            result() {
              printf '{"status":"%s","url":"%s","ref":"%s","dir":"%s","credential":"%s","sha":"%s"}\n' \
                "$status" "$url" "$ref" "$dir" "$cred" "$sha" >"$d/repo-status.json.tmp" && mv -f "$d/repo-status.json.tmp" "$d/repo-status.json"
            }
            die() { status=failed; result; echo "cmux repo: $1" >&2; exit 1; }
            # Nothing inherited or configured may ask another credential source or log a request (git's
            # stderr goes to the bootstrap log). Trace2 reads its config before any -c, so it is off here.
            export GIT_TERMINAL_PROMPT=0 GIT_TRACE_REDACT=1 GIT_TRACE=0 GIT_TRACE_CURL=0 GIT_TRACE_PACKET=0 GIT_TRACE_SETUP=0 \
              GIT_TRACE_PERFORMANCE=0 GIT_TRACE2=0 GIT_TRACE2_EVENT=0 GIT_TRACE2_PERF=0
            unset GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CURL_VERBOSE GIT_TRACE_CURL_NO_DATA
            # The machine's own GitHub paths, in order: the lane broker's helper (exactly the value
            # leo-workspace tools/lane-vm-bootstrap installs), the Cloud agent's, none.
            lane="!$HOME/.local/bin/lane-gh-credential"
            creds=""
            if [ -x "$HOME/.local/bin/lane-gh-credential" ] &&
              git config --global --includes --get-all credential.https://github.com.helper 2>/dev/null | grep -qxF -- "$lane"; then
              creds="lane-gh"
            fi
            if [ -S /run/cmux-vm-agent/agent.sock ] && cm=$(command -v cmux); then creds="$creds cmux-github"; fi
            creds="$creds anonymous"
            # From here git reads no user or system config (a username that is a secret, an askpass, a
            # helper, a trace target): the chosen helper comes on the command line.
            export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
            use() {
              cred=$1
              case "$1" in
                lane-gh) helper=$lane ;;
                cmux-github) helper="!'$cm' github credential" ;;
                *) helper="" ;;
              esac
            }
            # An empty credential.helper on the command line drops every helper git read before it (a
            # checkout's own config may hold one); the chosen one comes after it, so only it is asked.
            # The usernames are emptied for the same reason.
            g() {
              if [ -n "$helper" ]; then
                set -- -c "credential.https://github.com.helper=$helper" -c credential.https://github.com.useHttpPath=true "$@"
              fi
              git -c credential.helper= -c core.askPass= -c credential.username= -c credential.https://github.com.username= "$@"
            }
            # A clone or fetch with each path until one works; the checkout after it keeps that path.
            # A clone that failed half way (its checkout) is removed before the next path tries.
            net() {
              for c in $creds; do
                use "$c"; g "$@" && return 0
                [ -n "$fresh" ] && rm -rf "$dir"
              done
              status=needs_github; cred=none; result
              echo "cmux repo: $url needs GitHub access this machine does not have (private, not found, or offline)" >&2
              exit \#(Self.needsGitHubExit)
            }
            # Switch to $ref: a local or remote branch (tracked), else a tag or commit (detached).
            switch() {
              [ -n "$ref" ] || return 0
              if g -C "$dir" show-ref --verify --quiet "refs/heads/$ref"; then
                g -C "$dir" checkout --quiet "$ref" --
              elif g -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$ref"; then
                g -C "$dir" checkout --quiet -b "$ref" --track "origin/$ref" --
              elif commit=$(g -C "$dir" rev-parse --verify --quiet "$ref^{commit}"); then
                g -C "$dir" checkout --quiet --detach "$commit" --
              else
                why="no branch, tag or commit $ref in $url"; return 1
              fi || { why="cannot check out $ref"; return 1; }
            }
            # Fast-forward the checked-out branch to its upstream; a branch with local commits is kept.
            forward() {
              up=$(g -C "$dir" rev-parse --verify --quiet '@{u}') || return 0
              if g -C "$dir" merge-base --is-ancestor HEAD "$up"; then
                g -C "$dir" merge --quiet --ff-only "$up" || { why="cannot fast-forward to $up"; return 1; }
              else
                status=kept
              fi
            }
            if [ -d "$dir/.git" ]; then
              [ "$(git -C "$dir" remote get-url origin 2>/dev/null)" = "$url" ] || die "$dir holds another repository"
              # A clone cut short (no commit checked out) is cloned again.
              if ! g -C "$dir" rev-parse --verify --quiet HEAD >/dev/null; then
                [ -z "$(ls -A "$dir" | grep -vx .git)" ] || die "$dir has no commit checked out and holds files"
                rm -rf "$dir"
              fi
            fi
            if [ -d "$dir/.git" ]; then
              net -C "$dir" fetch --quiet --tags origin
              status=updated
              # A checkout with local changes stays as it is.
              changes=$(g -C "$dir" status --porcelain) || die "cannot read $dir"
              if [ -n "$changes" ]; then status=kept; else switch && forward || die "$why"; fi
            elif [ -e "$dir" ]; then
              die "$dir exists and is not a git checkout"
            else
              mkdir -p "$(dirname "$dir")"
              fresh=1
              net clone --quiet --filter=blob:none "$url" "$dir"
              switch || { rm -rf "$dir"; die "$why"; }
              status=cloned
            fi
            sha=$(g -C "$dir" rev-parse --verify --quiet HEAD) || die "no commit checked out in $dir"
            result
            """#
    }
}
