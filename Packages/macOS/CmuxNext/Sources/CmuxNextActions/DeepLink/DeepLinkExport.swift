public import Foundation

/// plans/cmux-next/links.json: cmux-next's object links as data, for clients
/// that make the same links without being cmux-next (GPUI's Copy Link). The
/// URL shape, the kinds and their id rules come from `DeepLink` itself: each
/// example is built by `DeepLink.url(scheme:)` and each rule by the same
/// constants its validator uses (cmux-action-catalog `deep_link::export`). The schemes per build come from the caller
/// (the app's `CloudConfiguration`, which registers them), so the export and
/// the app cannot disagree. A test in the App keeps the file fresh
/// (`CMUX_UPDATE_ACTION_SURFACES=1`, scripts/measure/export-action-surfaces.sh).
public nonisolated struct DeepLinkExport: Sendable {
    /// The URL scheme one kind of build registers and writes.
    public struct Scheme: Sendable, Hashable {
        /// `release`, `nightly`, `rc`, `debug` or `tagged`.
        public var build: String
        public var bundleID: String?
        /// The scheme, or for `tagged` the one an example tag gives.
        public var scheme: String
        /// For `tagged`: the tag the example scheme was made from.
        public var exampleTag: String?

        public init(build: String, bundleID: String?, scheme: String, exampleTag: String? = nil) {
            self.build = build
            self.bundleID = bundleID
            self.scheme = scheme
            self.exampleTag = exampleTag
        }
    }

    public var schemes: [Scheme]

    public init(schemes: [Scheme]) {
        self.schemes = schemes
    }

    /// The schemes a links.json states (its `schemes` rows), for a build of the export that does not link
    /// the app's `CloudConfiguration` (the Linux action exporter): the rest of the file is remade from `DeepLink`.
    public init(schemesOf links: Data) throws {
        let root = try JSONSerialization.jsonObject(with: links) as? [String: Any]
        guard let rows = root?["schemes"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        self.init(schemes: try rows.map { row in
            guard let build = row["build"] as? String, let scheme = row["scheme"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            return Scheme(build: build, bundleID: row["bundle_id"] as? String, scheme: scheme, exampleTag: row["example_tag"] as? String)
        })
    }

    /// The scheme a client that is not a shipping cmux build writes: the
    /// release build's, so the link opens the user's installed cmux.
    public var targetScheme: String? { schemes.first { $0.build == "release" }?.scheme }

    /// The export as pretty-printed, key-sorted JSON (a trailing newline), written by the Rust
    /// `deep_link` export from the same rules its links are made by.
    public func json() -> String {
        let rows: [[String: Any]] = schemes.map { scheme in
            var row: [String: Any] = ["build": scheme.build, "scheme": scheme.scheme]
            if let bundleID = scheme.bundleID { row["bundleID"] = bundleID }
            if let tag = scheme.exampleTag { row["exampleTag"] = tag }
            return row
        }
        return RustDeepLink.text(["op": "export", "schemes": rows]) ?? ""
    }
}
