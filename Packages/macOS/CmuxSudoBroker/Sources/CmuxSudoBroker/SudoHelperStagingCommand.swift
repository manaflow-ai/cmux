import Foundation

/// Builds the fixed root-side command that stages and re-verifies a bundled helper.
///
/// `sudo` runs `/bin/sh` with this constant program. As root it copies at most
/// ``maximumHelperBytes`` of the helper into a fresh root-owned `0700` directory, checks the
/// copy's SHA-256 against the sealed digest, checks a Mach-O copy against the pinned code
/// requirement, and only then executes the copy. The user-writable bundle path is never executed.
struct SudoHelperStagingCommand: Sendable, Equatable {
    static let rootStagingParent = "/private/var/root"
    static let argumentZero = "cmux-sudo-stage"
    static let shell = "/bin/sh"

    let stagingParent: String
    let maximumHelperBytes: Int

    init(
        stagingParent: String = Self.rootStagingParent,
        maximumHelperBytes: Int = SudoResourcePolicy.standard.maximumHelperBytes
    ) {
        precondition(
            stagingParent.hasPrefix("/") && stagingParent.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0)
            },
            "staging parent must be a plain absolute path"
        )
        self.stagingParent = stagingParent
        self.maximumHelperBytes = max(1, maximumHelperBytes)
    }

    /// The exact argv (after `sudo`) that stages `helper` and runs it with `helperArguments`.
    func arguments(
        helper: SudoVerifiedHelper,
        failureMarker: Data,
        helperArguments: [String]
    ) -> [String] {
        [
            Self.shell,
            "-c",
            script,
            Self.argumentZero,
            helper.sourceURL.standardizedFileURL.path,
            helper.sha256,
            String(maximumHelperBytes),
            helper.requirement?.text ?? "",
            helper.interpreter ?? "",
            String(decoding: failureMarker, as: UTF8.self),
        ] + helperArguments
    }

    /// The number of argv entries preceding the helper's own arguments.
    static let prefixCount = 10

    var script: String {
        """
        set -u
        src=$1 expected=$2 limit=$3 requirement=$4 interpreter=$5 marker=$6
        shift 6
        fail() {
          if [ -n "$marker" ]; then printf '%s' "$marker" >&2; fi
          exit 125
        }
        case $expected in *[!0-9a-f]*|'') fail ;; esac
        [ "${#expected}" -eq 64 ] || fail
        case $limit in *[!0-9]*|'') fail ;; esac
        case $interpreter in ''|/bin/bash) ;; *) fail ;; esac
        [ -f "$src" ] && [ ! -h "$src" ] || fail
        umask 077
        stage=$(/usr/bin/mktemp -d '\(stagingParent)/.cmux-sudo-helper.XXXXXX') || fail
        trap '/bin/rm -rf "$stage"' EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM
        helper=$stage/helper
        /usr/bin/head -c "$((limit + 1))" < "$src" > "$helper" || fail
        size=$(/usr/bin/stat -f %z "$helper") || fail
        [ "$size" -le "$limit" ] || fail
        actual=$(/usr/bin/shasum -a 256 "$helper") || fail
        actual=${actual%% *}
        [ "$actual" = "$expected" ] || fail
        if [ -n "$requirement" ]; then
          /usr/bin/codesign --verify --strict -R="$requirement" "$helper" >/dev/null 2>&1 || fail
        fi
        if [ -n "$interpreter" ]; then
          /bin/chmod 0400 "$helper" || fail
          "$interpreter" "$helper" "$@"
        else
          /bin/chmod 0500 "$helper" || fail
          "$helper" "$@"
        fi
        status=$?
        exit "$status"
        """
    }
}
