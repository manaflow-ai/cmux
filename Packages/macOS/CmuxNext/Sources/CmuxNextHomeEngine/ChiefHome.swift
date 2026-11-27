public import CmuxNextCompat
internal import CmuxNextHomeModel
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
/// 4. Every build but NIGHTLY: `~/.cmux/chief/<bundle id>` (a DEV build's
///    build key, ``folderName(of:appBuild:bundleID:tag:)``: the same name
///    for a tagged or the untagged DEV build, `<bundle id>--<tag>` for a copy
///    of one bundle id that ships its own `CMUX_TAG`), with
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
    /// share one Chief (Rust `chief_home.has_own_home`).
    public static func hasOwnHome(bundleID: String?) -> Bool {
        struct Request: Encodable { let bundleID: String? }
        struct Reply: Decodable { let ownHome: Bool }
        return ((try? ChiefHomeRules().call("has_own_home", Request(bundleID: bundleID))) as Reply?)?.ownHome ?? false
    }

    /// Whether this home may take in the old per-tag Chiefs (`ChiefMigration`):
    /// only NIGHTLY's (per-build isolation S6, cx-is1kf.7), never a build's
    /// own home, an explicit test home (rule 1) or a home of no bundle.
    public var importsOldChiefs: Bool { described?.importsOldChiefs ?? false }

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

    private struct AppAcpmuxRequest: Encodable {
        var isolated = false
        var buildID: String?
        var ownAcpmux: Bool?
        var environment: [String: String] = [:]
    }

    private struct AppAcpmuxReply: Decodable {
        let ownAcpmux: Bool
        let usesAppAcpmux: Bool
    }

    static func ownAcpmux(_ environment: [String: String]) -> Bool {
        let reply: AppAcpmuxReply? = try? ChiefHomeRules().call("uses_app_acpmux", AppAcpmuxRequest(environment: environment))
        return reply?.ownAcpmux ?? false
    }

    static func usesAppAcpmux(isolated: Bool, buildID: String?, ownAcpmux: Bool) -> Bool {
        let reply: AppAcpmuxReply? = try? ChiefHomeRules().call(
            "uses_app_acpmux", AppAcpmuxRequest(isolated: isolated, buildID: buildID, ownAcpmux: ownAcpmux))
        return reply?.usesAppAcpmux ?? false
    }
    /// The conversation owner's cmux-tui session (its socket name).
    public var session: String { Self.sessionName(root: root) }

    public init(root: URL, isolated: Bool, buildID: String? = nil) {
        self.root = root
        self.isolated = isolated
        self.buildID = buildID
    }

    /// The home's rules as Rust derives them (`chief_home.describe`); nil when the call fails.
    private var described: Described? {
        struct Request: Encodable { let root: String; let isolated: Bool; let buildID: String? }
        return try? ChiefHomeRules().call("describe", Request(root: root.path, isolated: isolated, buildID: buildID))
    }

    private struct Described: Decodable {
        let root: String
        let isolated: Bool
        let buildID: String?
        let importsOldChiefs: Bool
    }

    private struct Build: Encodable {
        let bundleID: String?
        let tag: String?
    }

    private struct ResolveRequest: Encodable {
        let tag: String?
        let environment: [String: String]
        let userHome: String
        let bundleID: String?
        let appBuild: Build?
        let isDebugBuild: Bool
    }

    /// The home of this build (rules 1-4 above, Rust `chief_home.resolve`). `appBuild` is the app's build
    /// (this process's when `bundleID` is the main bundle's; else `bundleID` with `tag`): a DEV build's
    /// folder is its build key (``BuildIdentity/stateFolderName(for:)``). When the rules cannot run, an
    /// isolated home, so it never touches the user's real Chief.
    public static func resolve(tag: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                               bundleID: String? = Bundle.main.bundleIdentifier,
                               build appBuild: BuildIdentity? = nil,
                               isDebugBuild: Bool = ChiefHome.isDebugBuild) -> ChiefHome {
        let identity = appBuild ?? (bundleID == Bundle.main.bundleIdentifier ? BuildStatePaths.current.build : nil)
        let request = ResolveRequest(tag: tag, environment: environment, userHome: userHome.path, bundleID: bundleID,
                                     appBuild: identity.map { Build(bundleID: $0.bundleID, tag: $0.tag) },
                                     isDebugBuild: isDebugBuild)
        guard let home: Described = try? ChiefHomeRules().call("resolve", request) else {
            return ChiefHome(root: userHome.appendingPathComponent(".cmux/chief/isolated/untagged", isDirectory: true), isolated: true)
        }
        return ChiefHome(root: URL(fileURLWithPath: home.root, isDirectory: true), isolated: home.isolated, buildID: home.buildID)
    }

    /// The directory that holds every Chief home of this user (rules 2 and 4):
    /// `CMUX_NEXT_CHIEF_ROOT`, else `~/.cmux/chief`. Isolated homes are under its `isolated/`.
    public static func chiefRoot(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        struct Request: Encodable { let environment: [String: String]; let userHome: String }
        struct Reply: Decodable { let root: String }
        guard let reply: Reply = try? ChiefHomeRules().call("chief_root", Request(environment: environment, userHome: userHome.path)) else {
            return userHome.appendingPathComponent(".cmux/chief", isDirectory: true)
        }
        return URL(fileURLWithPath: reply.root, isDirectory: true)
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

    private struct PathRequest: Encodable { let path: String }

    /// `chief:<home id>`, the agent tab host of the Chief home `muxHome`: its subagent tabs record
    /// it. The id is optchat-chief `paths::home_id`: FNV-1a 32 of the path bytes.
    public static func tabHost(muxHome: URL) -> String {
        struct Reply: Decodable { let tabHost: String }
        let reply: Reply? = try? ChiefHomeRules().call("tab_host", PathRequest(path: muxHome.path))
        return reply?.tabHost ?? tabHostPrefix
    }

    /// `cmux-chief-<FNV-1a 32 of the root path>`: one owner per home, short
    /// enough for the socket path; the CLI derives the same name.
    static func sessionName(root: URL) -> String {
        struct Reply: Decodable { let session: String }
        let reply: Reply? = try? ChiefHomeRules().call("session_name", PathRequest(path: root.path))
        return reply?.session ?? "cmux-chief-"
    }

    /// A path component: runs of anything outside `[A-Za-z0-9._]` become one
    /// `-`; nil when nothing is left.
    static func component(of raw: String) -> String? {
        struct Request: Encodable { let raw: String }
        struct Reply: Decodable { let component: String? }
        let reply: Reply? = try? ChiefHomeRules().call("component", Request(raw: raw))
        return reply?.component
    }
}

/// The `chief_home` area of the Rust home rules (cmux-home-rules `chief_home`), through ``HomeRules``.
/// `package`: CmuxNextHostedChief's thin callers use it too.
/// Any Rust home rule (`cmux_home_call`), for the service targets that may not import
/// CmuxNextHomeModel (the layer gate): CmuxNextHostedChief's `chiefs_*` and `reach_*` ops.
package nonisolated enum HomeEngineRules {
    package static func call<In: Encodable, Out: Decodable>(_ op: String, _ input: In) throws -> Out {
        try HomeRules.call(op, input)
    }
}

package nonisolated struct ChiefHomeRules: Sendable {
    package init() {}

    package func call<In: Encodable, Out: Decodable>(_ name: String, _ input: In) throws -> Out {
        try HomeRules.call("chief_home." + name, input)
    }

    /// Runs `name` on `{"value": value}`, a JSON value the app decoded (`JSONSerialization`).
    package func call<Out: Decodable>(_ name: String, value: Any?) throws -> Out {
        let request: [String: Any] = ["value": value ?? NSNull()]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw HomeRulesError(op: "chief_home." + name, code: .encode, detail: "not a JSON value")
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = try HomeRules.callJSON("chief_home." + name, String(decoding: data, as: UTF8.self))
        do {
            return try JSONDecoder().decode(Out.self, from: Data(reply.utf8))
        } catch {
            throw HomeRulesError(op: "chief_home." + name, code: .decode, detail: String(describing: error))
        }
    }
}
