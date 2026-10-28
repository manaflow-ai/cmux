public import Foundation

/// The home of one build's Chief (plans/cmux-next/home-state-ownership.md):
/// the OptChat memory and host state (`optchat/`, `state/host.lock`), the
/// conversation owner that holds Home's conversations (`tui/`, its own
/// cmux-tui daemon session) and the acpmux daemon of the Chief's turns and
/// subagents (`acpmux/`).
///
/// One Chief per build (Lawrence, 2026-10-14: "we need a chief per build,
/// should not overlap"): every DEV and staging build, keyed by its bundle
/// id, has its own home, so it never starts, stops or reads another build's
/// brain, acpmux, tools socket or memory, and its quit stops only its own
/// Chief. NIGHTLY (`com.cmuxterm.app.nightly` only), Lawrence's daily
/// Chief, keeps the home all builds shared before (`~/.cmux/chief/<account>`)
/// where it is: nothing is moved or copied, so its memory and history stay
/// as they are. Every other build (DEV, staging, cmux NEXT's
/// `com.cmuxterm.app.nightly.cmux-next`, RC, release) has its own home, so
/// two NIGHTLY identities that run at the same time never share one Chief.
/// A build's own home starts empty and never imports the old per-tag Chiefs
/// (`ChiefMigration` runs only for NIGHTLY's home, after its one-time
/// backup, `ChiefAdoption`).
///
/// Resolution, first match wins:
/// 1. `CMUX_NEXT_CHIEF_HOME` (or the older `CMUX_NEXT_MUX_HOME`): that
///    directory, for tests and preflights that share one home on purpose.
/// 2. `CMUX_NEXT_CHIEF_ROOT`: the per-build rule (3) below that directory
///    instead of `~/.cmux/chief`, isolation markers ignored (behavior tests
///    of the per-build homes and the NIGHTLY adoption).
/// 3. An isolated launch (`CMUX_NEXT_CHIEF_ISOLATED=1`, agent preflights with
///    `CMUX_NEXT_NO_ACTIVATE=1`, test window placement, showcase):
///    `~/.cmux/chief/isolated/<tag>`, so automation never reads or writes the
///    user's real Chief.
/// 4. Every build but NIGHTLY: `~/.cmux/chief/<bundle id>`, with
///    `.<account>` appended for an account other than `default`. NIGHTLY
///    (and a process without a bundle id): `~/.cmux/chief/<account>` (the
///    account from `CMUX_NEXT_CHIEF_ACCOUNT`, else `default`). A DEBUG build may name
///    another bundle id in `CMUX_NEXT_CHIEF_BUILD_ID` (tests only).
///
/// Builds from before one Chief per build still resolve
/// `~/.cmux/chief/<account>`, NIGHTLY's home. They cannot damage its memory:
/// the brain's flock on `state/host.lock` keeps one writer, and when an
/// older build's quit stops that brain, NIGHTLY starts it again
/// (`ChiefBrainWatch`).
///
/// The `cmux chief` CLI resolves the same home for the app it belongs to
/// (cmux-tui `cli/chief/home.rs`); the app's terminals also get it as
/// `CMUX_CHIEF_HOME`.
public nonisolated struct ChiefHome: Sendable, Equatable {
    public let root: URL
    /// An isolated (test or preflight) home, never the user's Chief.
    public let isolated: Bool
    /// The bundle id this home belongs to (rules 2 and 4), nil for rules 1 and 3.
    public var buildID: String? = nil

    /// The one build that keeps the shared home, `~/.cmux/chief/<account>`.
    public static let nightlyBundleID = "com.cmuxterm.app.nightly"

    /// Whether `bundleID` gets a Chief home of its own: every build but
    /// NIGHTLY, so two identities that run at the same time (NIGHTLY and
    /// cmux NEXT's `com.cmuxterm.app.nightly.cmux-next`, RC, release) never
    /// share one Chief.
    public static func hasOwnHome(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return bundleID != nightlyBundleID
    }

    /// Whether this home may take in the old per-tag Chiefs (`ChiefMigration`):
    /// only NIGHTLY's (per-build isolation S6, cx-is1kf.7), never a build's
    /// own home, an explicit test home (rule 1) or a home of no bundle.
    public var importsOldChiefs: Bool { !isolated && buildID == Self.nightlyBundleID }

    /// `--mux-home` of the brain host: OptChat memory under `optchat/`,
    /// the single-writer host lock at `state/host.lock`.
    public var muxHome: URL { root }
    /// `CMUX_TUI_STATE_DIR` of the Chief's conversation owner.
    public var daemonStateDirectory: URL { root.appendingPathComponent("tui", isDirectory: true) }
    /// Written by `cmux chief shutdown` (cmux-tui `cli/chief/shutdown.rs`):
    /// while it is there the app starts no brain on its own, only when asked.
    var shutdownMarker: URL { root.appendingPathComponent("state/shutdown") }
    /// While a turn waits for the compactor: how far it is (optchat-chief settle_status.rs).
    var settleStatusFile: URL { root.appendingPathComponent("state/settle.json") }
    /// `ACPMUX_HOME` of the Chief's own daemon, where its turn, compactor and subagent sessions
    /// run unless it uses the app's (``usesAppAcpmux``).
    public var acpmuxHome: URL { root.appendingPathComponent("acpmux", isDirectory: true) }
    /// Whether this Chief runs on the app's own acpmux (`~/.acpmux`, the one daemon of this
    /// machine) instead of ``acpmuxHome``: NIGHTLY's home only, unless `CMUX_CHIEF_OWN_ACPMUX=1` in
    /// the app's environment brings the old daemon back. The app then starts and hands off that
    /// daemon; the Chief host only waits for it (`OPTCHAT_ACPMUX_SUPERVISED=1`) and never starts or
    /// stops it, and the Chief's sessions stay apart by their tags (`cmux.chief`, `mux.parent`).
    public var usesAppAcpmux: Bool {
        Self.usesAppAcpmux(isolated: isolated, buildID: buildID, ownAcpmux: Self.ownAcpmuxAtLaunch)
    }

    /// `CMUX_CHIEF_OWN_ACPMUX=1`, read once from the process environment, so the tab wiring, the
    /// error journal and the Chief host, which resolve at different points of the launch, agree.
    private static let ownAcpmuxAtLaunch = ownAcpmux(ProcessInfo.processInfo.environment)

    static func ownAcpmux(_ environment: [String: String]) -> Bool {
        environment["CMUX_CHIEF_OWN_ACPMUX"] == "1"
    }

    static func usesAppAcpmux(isolated: Bool, buildID: String?, ownAcpmux: Bool) -> Bool {
        !isolated && buildID == nightlyBundleID && !ownAcpmux
    }
    /// The conversation owner's cmux-tui session (its socket name).
    public var session: String { Self.sessionName(root: root) }

    public init(root: URL, isolated: Bool, buildID: String? = nil) {
        self.root = root
        self.isolated = isolated
        self.buildID = buildID
    }

    public static func resolve(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                               bundleID: String? = Bundle.main.bundleIdentifier,
                               isDebugBuild: Bool = ChiefHome.isDebugBuild) -> ChiefHome {
        let value = { (key: String) in environment[key].flatMap { $0.isEmpty ? nil : $0 } }
        if let explicit = value("CMUX_NEXT_CHIEF_HOME") ?? value("CMUX_NEXT_MUX_HOME") {
            return ChiefHome(root: URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL, isolated: false)
        }
        let rootOverride = value("CMUX_NEXT_CHIEF_ROOT").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let base = chiefRoot(environment: environment, userHome: userHome)
        let isolatedLaunch = value("CMUX_NEXT_CHIEF_ISOLATED") == "1" || value("CMUX_NEXT_NO_ACTIVATE") == "1"
            || value("CMUX_NEXT_SHOWCASE") == "1"
            || value("CMUX_NEXT_TEST_WINDOW_FRAME") != nil || value("CMUX_NEXT_TEST_WINDOW_SCREEN") != nil
        if isolatedLaunch, rootOverride == nil {
            let component = tag.flatMap(component(of:)) ?? "untagged"
            return ChiefHome(root: base.appendingPathComponent("isolated/\(component)", isDirectory: true), isolated: true)
        }
        let account = value("CMUX_NEXT_CHIEF_ACCOUNT").flatMap(component(of:)) ?? "default"
        let build = (isDebugBuild ? value("CMUX_NEXT_CHIEF_BUILD_ID") : nil) ?? bundleID
        guard hasOwnHome(bundleID: build), let build, let name = component(of: build) else {
            return ChiefHome(root: base.appendingPathComponent(account, isDirectory: true), isolated: false, buildID: build)
        }
        let root = base.appendingPathComponent(account == "default" ? name : "\(name).\(account)", isDirectory: true)
        return ChiefHome(root: root, isolated: false, buildID: build)
    }

    /// The directory that holds every Chief home of this user (rules 2 and 4):
    /// `CMUX_NEXT_CHIEF_ROOT`, else `~/.cmux/chief`. Isolated homes are under its `isolated/`.
    public static func chiefRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let override = environment["CMUX_NEXT_CHIEF_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return userHome.appendingPathComponent(".cmux/chief", isDirectory: true)
    }

    /// Whether a Chief brain host holds this home now (the flock on `state/host.lock`). It reads
    /// the disk: never on the main thread.
    public var hostRuns: Bool {
        ChiefMigration.lockHeld(at: root.appendingPathComponent("state/host.lock"))
    }

    /// A Debug compile (DEV builds); NIGHTLY and Release compile as Release.
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Every Chief home's agent tab host starts with it: `chief:<home id>`.
    public static let tabHostPrefix = "chief:"

    /// `chief:<home id>`, the agent tab host of the Chief home `muxHome`: its subagent tabs record
    /// it. The id is optchat-chief `paths::home_id`: FNV-1a 32 of the path bytes.
    public static func tabHost(muxHome: URL) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in muxHome.path.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return tabHostPrefix + String(format: "%08x", hash)
    }

    /// `cmux-chief-<FNV-1a 32 of the root path>`: one owner per home, short
    /// enough for the socket path; the CLI derives the same name.
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
