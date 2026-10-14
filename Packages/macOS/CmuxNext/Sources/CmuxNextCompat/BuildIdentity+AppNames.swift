public import Foundation

/// The app daemon session, control socket and daemon state directory of a
/// build (per-build isolation S3, cx-is1kf.4; Rust mirror
/// `build_identity::BuildIdentity::app_session`, vectors `app_daemon`).
///
/// A build keeps the names it had before per-build isolation where they
/// belong to exactly one build, so no state moves and tag-addressed tooling
/// (`cmux-app-<tag>`, `/tmp/cmux-debug-<tag>.sock`) keeps working: release,
/// the untagged NIGHTLY, RC and staging builds, cmux NEXT, and a
/// `scripts/reload.sh` DEV build `com.cmuxterm.app.debug.<a.b>` whose suffix
/// is its tag, and the plain DEV bundle with a tag (shipped, or from its
/// `cmux DEV <tag>.app` name, ``LaunchIdentity``). Every other build (the
/// untagged DEV build, a DEV build tagged with a name a shipped build owns, a
/// bundle that ships another tag than its id, an unknown bundle) gets names
/// of its key: `cmux-app--<key hash>`,
/// `/tmp/cmux-<kind>--<key hash>.sock`, `builds/<key>/tui` (`--` never
/// occurs in a tag).
extension BuildIdentity {
    /// The session tag (`cmux-app[-<tag>]`) and control socket name
    /// (`/tmp/cmux-<name>.sock`; nil: release's `~/.local/state/cmux/cmux.sock`)
    /// a build keeps.
    struct KeptNames: Sendable, Equatable {
        let sessionTag: String?
        let socket: String?

        private static let channels = [
            ("com.cmuxterm.app.nightly", "nightly"), ("com.cmuxterm.app.rc", "rc"),
            ("com.cmuxterm.app.staging", "staging"),
        ]
        /// cmux NEXT, shipped (`nightly-next`): its installs keep their daemon state.
        private static let cmuxNextBundleID = "com.cmuxterm.app.nightly.cmux-next"
        /// DEV tags whose names a shipped build owns.
        private static let ownedTags: Set<String> = ["nightly", "rc", "staging", "cmux-next"]

        /// The names `bundleID` (`suffix` after its kind's prefix, shipped
        /// tag slug `shipped`) keeps, or nil. Byte comparisons, as in Rust.
        static func of(bundleID: String, suffix: String?, shipped: String?) -> KeptNames? {
            let id = Array(bundleID.utf8)
            // The plain DEV bundle with a tag (shipped, or from its `cmux DEV
            // <tag>.app` name) keeps that tag's names, as before; untagged: none.
            if id == Array("com.cmuxterm.app.debug".utf8) {
                guard let shipped, !ownedTags.contains(shipped) else { return nil }
                return KeptNames(sessionTag: shipped, socket: "debug-\(shipped)")
            }
            let suffixTag = suffix.flatMap(BuildIdentity.tagSlug(of:))
            if let shipped, shipped != suffixTag { return nil }
            if id == Array("com.cmuxterm.app".utf8) { return KeptNames(sessionTag: nil, socket: nil) }
            if let channel = channels.first(where: { Array($0.0.utf8) == id })?.1 {
                return KeptNames(sessionTag: channel, socket: channel)
            }
            if id == Array(cmuxNextBundleID.utf8) {
                return KeptNames(sessionTag: "cmux-next", socket: "nightly-cmux-next")
            }
            let prefix = Array("com.cmuxterm.app.debug.".utf8)
            guard id.count > prefix.count, id.starts(with: prefix) else { return nil }
            let reloadForm = id[prefix.count...]
                .split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
                .allSatisfy { segment in
                    !segment.isEmpty && segment.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) }
                }
            guard reloadForm, let tag = suffixTag, !ownedTags.contains(tag) else { return nil }
            return KeptNames(sessionTag: tag, socket: "debug-\(tag)")
        }
    }

    /// Whether this build keeps the app names it had before per-build
    /// isolation; false: its names are of its key.
    public var keepsAppNames: Bool { kept != nil }

    /// The session of this build's app daemon: `cmux-app` (release),
    /// `cmux-app-<tag>` (a kept name), else `cmux-app--<key hash>`. Nil
    /// outside any bundle.
    public var appSession: String? {
        guard kind != .unbundled else { return nil }
        switch kept {
        case .some(let names): return names.sessionTag.map { "cmux-app-\($0)" } ?? "cmux-app"
        case .none: return "cmux-app--\(keyHash)"
        }
    }

    /// The control socket of this build's app: a kept path
    /// (`/tmp/cmux-<channel>.sock`, `/tmp/cmux-debug-<tag>.sock`, release's
    /// `~/.local/state/cmux/cmux.sock`), else
    /// `/tmp/cmux-<kind>--<key hash>.sock` (`debug` for DEV). Nil outside any bundle.
    public func controlSocket(userHome: URL) -> String? {
        let word: String
        switch kind {
        case .unbundled: return nil
        case .dev: word = "debug"
        default: word = kind.rawValue
        }
        switch kept {
        case .some(let names):
            return names.socket.map { "/tmp/cmux-\($0).sock" }
                ?? userHome.appendingPathComponent(".local/state/cmux/cmux.sock").path
        case .none: return "/tmp/cmux-\(word)--\(keyHash).sock"
        }
    }

    /// The app daemon's state directory (`CMUX_TUI_STATE_DIR`) under
    /// `appSupport` (`~/Library/Application Support/cmux`): `tags/<tag>/tui`
    /// for a kept tag, `builds/<key>/tui` for names of the key, nil for
    /// release (cmux-tui's default root) and outside any bundle.
    public func daemonStateDirectory(appSupport: URL) -> URL? {
        guard kind != .unbundled else { return nil }
        switch kept {
        case .some(let names):
            return names.sessionTag.map { appSupport.appendingPathComponent("tags/\($0)/tui", isDirectory: true) }
        case .none: return appSupport.appendingPathComponent("builds/\(key)/tui", isDirectory: true)
        }
    }
}
