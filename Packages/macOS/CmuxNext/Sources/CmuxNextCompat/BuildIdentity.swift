public import Foundation

/// Which cmux build this process belongs to, and the state roots it owns.
///
/// Lawrence, 2026-10-14: "each dev app chiefs/imessage stuff is isolated".
/// One build never reads, starts, stops or adopts another build's state, so
/// every root that holds state is derived from one key here: the bundle id,
/// plus the tag the bundle ships (`LSEnvironment` `CMUX_TAG`) when the
/// bundle id does not end in it. The tag comes from the bundle only, never
/// from an inherited environment, so a terminal of one build cannot make a
/// child resolve another build's roots.
///
/// NIGHTLY (`com.cmuxterm.app.nightly`, Lawrence's daily build) keeps the
/// roots every build shared before (`~/.cmux/chief/<account>`, `~/.acpmux`,
/// App Support `cmux/`) and adopts them in place. Every other build (DEV,
/// staging, cmux NEXT's `com.cmuxterm.app.nightly.cmux-next`, RC, release)
/// gets roots of its own under its key.
///
/// It lives in CmuxNextCompat because every CmuxNext target already depends
/// on it (it can move to its own target later; hq-6d 2026-10-14). The Rust mirror is cmux-tui `cmux_agent_pane_policy::build_identity`;
/// both follow
/// `schemas/build-identity/vectors.json`.
public nonisolated struct BuildIdentity: Sendable, Equatable {
    /// The kind of build a bundle id names.
    public enum Kind: String, Sendable {
        /// `com.cmuxterm.app.nightly[.<suffix>]` (cmux NEXT's `.cmux-next`).
        case nightly
        /// `com.cmuxterm.app`.
        case release
        /// `com.cmuxterm.app.rc[.<suffix>]`.
        case rc
        /// `com.cmuxterm.app.debug[.<tag>]`, and any other `com.cmuxterm.app.*`
        /// bundle (an unknown bundle is isolated like a DEV build).
        case dev
        /// `com.cmuxterm.app.staging[.<tag>]`.
        case staging
        /// No bundle id: a standalone process.
        case unbundled
    }

    /// The one bundle that keeps the shared roots of older builds.
    public static let nightlyBundleID = "com.cmuxterm.app.nightly"
    /// The key of a process outside any app bundle.
    public static let unbundledKey = "unbundled"

    /// The bundle id prefixes, longest first, and the kind each one names.
    private static let kinds: [(String, Kind)] = [
        ("com.cmuxterm.app.nightly", .nightly), ("com.cmuxterm.app.staging", .staging),
        ("com.cmuxterm.app.debug", .dev), ("com.cmuxterm.app.rc", .rc), ("com.cmuxterm.app", .release),
    ]

    public let bundleID: String?
    /// The sanitized tag (`[a-z0-9-]`): the one the bundle ships, else the
    /// bundle id's suffix.
    public let tag: String?
    public let kind: Kind
    /// The path component of this build's roots: the bundle id (plus
    /// `--<fnv1a32 of the id>` when the id is not already a path component of
    /// `[A-Za-z0-9._-]`), plus `--<tag>` when the bundle ships a tag its id
    /// does not end in; `unbundled` outside any bundle.
    public let key: String
    /// The app names this build keeps from before per-build isolation
    /// (``appSession``); nil: names of its key.
    let kept: KeptNames?

    /// The build of `bundleID` (`CFBundleIdentifier`) with the tag its bundle
    /// ships (`LSEnvironment` `CMUX_TAG`), if any. A suffix after the kind's
    /// prefix (`com.cmuxterm.app.debug.<tag>`) is the tag. Blank values
    /// count as absent.
    public init(bundleID rawBundleID: String?, bundledTag: String?) {
        guard let bundleID = rawBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else {
            self.bundleID = nil
            tag = nil
            kind = .unbundled
            key = Self.unbundledKey
            kept = nil
            return
        }
        // Byte comparisons, as in Rust: `hasPrefix` and `==` on String
        // compare canonical equivalents.
        let bytes = Array(bundleID.utf8)
        var kind = Kind.dev
        var suffix: String?
        for (prefix, candidate) in Self.kinds {
            let head = Array(prefix.utf8)
            if bytes == head {
                kind = candidate
                break
            }
            if bytes.count > head.count, bytes.starts(with: head), bytes[head.count] == UInt8(ascii: ".") {
                kind = candidate
                suffix = String(decoding: bytes[(head.count + 1)...], as: UTF8.self)
                break
            }
        }
        // `com.cmuxterm.app.<other>` is no known kind: isolated as DEV.
        if kind == .release, suffix != nil { kind = .dev }
        let suffixTag = suffix.flatMap(Self.tagSlug(of:))
        let shipped = bundledTag.flatMap(Self.tagSlug(of:))
        let tag = shipped ?? suffixTag
        // A bundle id that is not already a path component (an empty suffix,
        // other characters) gets a hash of the exact id, so two such ids
        // never share roots.
        var key: String
        switch Self.component(of: bundleID) {
        case let name? where Array(name.utf8) == bytes: key = name
        case let name?: key = "\(name)--\(Self.fnv1a32(bytes))"
        case nil: key = "\(Self.unbundledKey)--\(Self.fnv1a32(bytes))"
        }
        // A shipped tag the id does not end in (two builds of one bundle id
        // with different tags) keeps the builds apart.
        if let shipped, shipped != suffixTag { key += "--" + shipped }
        self.bundleID = bundleID
        self.tag = tag
        self.kind = kind
        self.key = key
        kept = KeptNames.of(bundleID: bundleID, suffix: suffix, shipped: shipped)
    }

    /// The running app: its bundle id and the `CMUX_TAG` its Info.plist
    /// ships in `LSEnvironment` (never the process environment).
    public init(bundle: Bundle) {
        let environment = bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: Any]
        self.init(bundleID: bundle.bundleIdentifier, bundledTag: environment?["CMUX_TAG"] as? String)
    }

    /// FNV-1a 32 of the key, 8 hex digits: for names that must stay short
    /// (socket paths, session names).
    public var keyHash: String { Self.fnv1a32(Array(key.utf8)) }

    private static func fnv1a32(_ bytes: [UInt8]) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
    }

    /// Whether this build keeps the shared roots of older builds in place:
    /// NIGHTLY (`com.cmuxterm.app.nightly`) only.
    public var keepsSharedRoots: Bool { bundleID.map { Array($0.utf8) == Array(Self.nightlyBundleID.utf8) } ?? false }

    private var ownsRoots: Bool { !keepsSharedRoots && kind != .unbundled }

    /// The Chief home: `~/.cmux/chief/<account>` for NIGHTLY and outside any
    /// bundle, else `~/.cmux/chief/<key>[@<account>]` (`account` other than
    /// `default`; `@` never appears in a key, so no account of one build
    /// names another build's home). `ChiefHome` moves to this rule when it
    /// adopts this type; today it writes `<bundle id>.<account>`.
    public func chiefHome(userHome: URL, account: String = "default") -> URL {
        let base = userHome.appendingPathComponent(".cmux/chief", isDirectory: true)
        let account = Self.component(of: account) ?? "default"
        let name = !ownsRoots ? account : account == "default" ? key : "\(key)@\(account)"
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// The acpmux home (`ACPMUX_HOME`): `~/.acpmux` for NIGHTLY and a
    /// standalone process, else `~/.acpmux/builds/<key>`.
    public func acpmuxHome(userHome: URL) -> URL {
        acpmuxHome(root: userHome.appendingPathComponent(".acpmux", isDirectory: true))
    }

    /// ``acpmuxHome(userHome:)`` with `root` standing for `~/.acpmux` (a test root).
    public func acpmuxHome(root: URL) -> URL {
        ownsRoots ? root.appendingPathComponent("builds/\(key)", isDirectory: true) : root
    }

    /// Candidate daemon homes for draft-only recovery. This never adopts sessions or
    /// daemon configuration; callers read only composer_draft from session metadata.
    public func legacyAcpmuxDraftHomes(userHome: URL) -> [URL] {
        let root = Self(bundleID: nil, bundledTag: nil).acpmuxHome(userHome: userHome)
        var homes = [acpmuxHome(root: root)]
        if draftIdentityKey == "channel-cmux-next" {
            homes.append(root.appendingPathComponent("tags/cmux-next", isDirectory: true))
        }
        // A key already encodes its complete identity, including any generated hash or shipped tag.
        homes.append(root.appendingPathComponent("builds/\(key)", isDirectory: true))
        var seen = Set<String>()
        return homes.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// This build's directory under `~/Library/Application Support/cmux`
    /// (`appSupport` is that `cmux` directory): the directory itself for
    /// NIGHTLY and outside any bundle, else `builds/<key>` below it.
    public func appSupport(_ appSupport: URL) -> URL {
        ownsRoots ? appSupport.appendingPathComponent("builds/\(key)", isDirectory: true) : appSupport
    }

    /// Stable logical app identity for unsent composer state. Build versions and shipped
    /// tags must not fork drafts, while unrelated channels and development tags stay isolated.
    public var draftIdentityKey: String {
        if let sessionTag = kept?.sessionTag { return "channel-\(sessionTag)" }
        if kind == .release, kept != nil { return "release" }
        return "build-\(key)"
    }

    /// App-owned draft state is outside per-build folders so updates retain it.
    public func draftDirectory(appSupport: URL) -> URL {
        appSupport.appendingPathComponent("drafts-v1/\(draftIdentityKey)", isDirectory: true)
    }

    /// A path component: runs outside `[A-Za-z0-9._]` become one `-`; no
    /// leading or trailing `-` or `.`; nil when nothing is left.
    public static func component(of raw: String) -> String? {
        var out = ""
        for scalar in raw.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "." || scalar == "_" {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A tag as the app sanitizes it (`ControlSocketPath.sanitize`):
    /// lowercase, runs outside `[a-z0-9]` become one `-`, no leading or
    /// trailing `-`. Unicode scalars, as Rust's `char`s.
    public static func tagSlug(of raw: String) -> String? {
        var slug = ""
        for scalar in raw.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? nil : trimmed
    }
}
