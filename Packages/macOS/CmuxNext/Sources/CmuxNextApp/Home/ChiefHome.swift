import Foundation

/// The one home of the user's Chief (plans/cmux-next/home-state-ownership.md):
/// the OptChat memory and host state (`optchat/`, `state/host.lock`), the
/// conversation owner that holds Home's conversations (`tui/`, its own
/// cmux-tui daemon session) and the acpmux daemon of the Chief's turns and
/// subagents (`acpmux/`). Every DEV tag, NIGHTLY and Release build of one
/// account resolves the same home, so the Home transcript and the Chief's
/// memory are one history whatever build opens it. A build never keeps
/// Chief state of its own: a tag decides only how the window looks.
///
/// Resolution, first match wins:
/// 1. `CMUX_NEXT_CHIEF_HOME` (or the older `CMUX_NEXT_MUX_HOME`): that
///    directory, for tests and preflights that share one home on purpose.
/// 2. An isolated launch (`CMUX_NEXT_CHIEF_ISOLATED=1`, agent preflights with
///    `CMUX_NEXT_NO_ACTIVATE=1`, test window placement, showcase):
///    `~/.cmux/chief/isolated/<tag>`, so automation never reads or writes the
///    user's real Chief.
/// 3. `~/.cmux/chief/<account>`, the account from `CMUX_NEXT_CHIEF_ACCOUNT`,
///    else `default` (the Mac Chief is per macOS user until the brain moves
///    to the cloud Chief, whose id then names the home).
nonisolated struct ChiefHome: Sendable, Equatable {
    let root: URL
    /// An isolated (test or preflight) home, never the user's Chief.
    let isolated: Bool

    /// `--mux-home` of the brain host: OptChat memory under `optchat/`,
    /// the single-writer host lock at `state/host.lock`.
    var muxHome: URL { root }
    /// `CMUX_TUI_STATE_DIR` of the Chief's conversation owner.
    var daemonStateDirectory: URL { root.appendingPathComponent("tui", isDirectory: true) }
    /// `ACPMUX_HOME` of the Chief's turn, compactor and subagent sessions.
    var acpmuxHome: URL { root.appendingPathComponent("acpmux", isDirectory: true) }
    /// The conversation owner's cmux-tui session (its socket name).
    var session: String { Self.sessionName(root: root) }

    static func resolve(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                        userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> ChiefHome {
        let value = { (key: String) in environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        if let explicit = value("CMUX_NEXT_CHIEF_HOME") ?? value("CMUX_NEXT_MUX_HOME") {
            return ChiefHome(root: URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL, isolated: false)
        }
        let base = userHome.appendingPathComponent(".cmux/chief", isDirectory: true)
        let isolatedLaunch = value("CMUX_NEXT_CHIEF_ISOLATED") == "1" || value("CMUX_NEXT_NO_ACTIVATE") == "1"
            || value("CMUX_NEXT_SHOWCASE") == "1"
            || value("CMUX_NEXT_TEST_WINDOW_FRAME") != nil || value("CMUX_NEXT_TEST_WINDOW_SCREEN") != nil
        if isolatedLaunch {
            let component = tag.flatMap(component(of:)) ?? "untagged"
            return ChiefHome(root: base.appendingPathComponent("isolated/\(component)", isDirectory: true), isolated: true)
        }
        let account = value("CMUX_NEXT_CHIEF_ACCOUNT").flatMap(component(of:)) ?? "default"
        return ChiefHome(root: base.appendingPathComponent(account, isDirectory: true), isolated: false)
    }

    /// `cmux-chief-<FNV-1a 32 of the root path>`: one owner per home, short
    /// enough for the socket path, and the same in every build.
    static func sessionName(root: URL) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in root.standardizedFileURL.path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return "cmux-chief-" + String(format: "%08x", hash)
    }

    /// A path component: runs of anything outside `[A-Za-z0-9._]` become one
    /// `-`; nil when nothing is left.
    static func component(of raw: String) -> String? {
        var out = ""
        for character in raw {
            if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" {
                out.append(character)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? nil : trimmed
    }
}
