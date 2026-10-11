public import Foundation

/// plans/cmux-next/links.json: cmux-next's object links as data, for clients
/// that make the same links without being cmux-next (GPUI's Copy Link). The
/// URL shape, the kinds and their id rules come from `DeepLink` itself: each
/// example is built by `DeepLink.url(scheme:)` and each rule by the same
/// constants its validator uses. The schemes per build come from the caller
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

    /// The scheme a client that is not a shipping cmux build writes: the
    /// release build's, so the link opens the user's installed cmux.
    public var targetScheme: String? { schemes.first { $0.build == "release" }?.scheme }

    /// Example ids that fit each kind's grammar.
    static let exampleHex = "0123456789abcdef0123456789abcdef"

    /// The export as pretty-printed, key-sorted JSON (a trailing newline).
    public func json() -> String {
        let scheme = targetScheme ?? "cmux"
        func example(_ target: DeepLink.Target, machine: String? = nil) -> String {
            DeepLink(target, machine: machine).url(scheme: scheme)?.absoluteString ?? ""
        }
        let resourceRule = "<prefix> + \(DeepLink.resourceHexDigits) lowercase hex digits [0-9a-f]"
        let tokenRule = "\(DeepLink.tokenLengths.lowerBound) to \(DeepLink.tokenLengths.upperBound) ASCII letters, digits, '-', '_' or '.'"
        let kinds: [[String: Any]] = [
            ["kind": "workspace", "id_prefix": "ws_", "id_rule": resourceRule,
             "example": example(.workspace("ws_" + Self.exampleHex))],
            ["kind": "pane", "id_prefix": "pane_", "id_rule": resourceRule,
             "example": example(.pane("pane_" + Self.exampleHex)), "opens": "the pane's selected tab"],
            ["kind": "tab", "id_prefix": "tab_", "id_rule": resourceRule,
             "example": example(.tab("tab_" + Self.exampleHex))],
            ["kind": "session", "id_rule": "an acpmux session id: \(tokenRule)",
             "turn": "optional fragment #\(DeepLink.turnFragmentPrefix)<turnId>; the turn id follows the same rule",
             "example": example(.session("ses-01.example_a", turn: nil)),
             "example_with_turn": example(.session("ses-01.example_a", turn: "turn_7"))],
        ]
        let root: [String: Any] = [
            "description": "cmux-next object links (Copy Workspace/Pane/Tab Link, agent chat sessions), generated from "
                + "CmuxNextActions/DeepLink (DeepLink.url) and CloudConfiguration.callbackScheme. Do not edit: "
                + "CMUX_UPDATE_ACTION_SURFACES=1 swift test --filter LinkExportTests rewrites it.",
            "shape": "<scheme>://<kind>/<id>[?machine=machine_<\(DeepLink.resourceHexDigits) hex>][#\(DeepLink.turnFragmentPrefix)<turnId>, session only]",
            "schemes": schemes.map { scheme -> [String: Any] in
                var row: [String: Any] = ["build": scheme.build, "scheme": scheme.scheme]
                if let bundleID = scheme.bundleID { row["bundle_id"] = bundleID }
                if let tag = scheme.exampleTag {
                    row["example_tag"] = tag
                    row["rule"] = "cmux-dev-<tag>, the tag lowercased, runs of [a-z0-9] joined by single hyphens"
                }
                return row
            },
            "target_scheme": scheme,
            "target_scheme_rule": "A client that is not a shipping cmux build writes the release scheme, so the link opens the user's installed cmux.",
            "kinds": kinds,
            "machine": "optional ?machine=machine_<\(DeepLink.resourceHexDigits) hex>: the machine the target lives on (a hint; ids are globally unique)",
            "ignored": "every other query parameter is ignored, so a link never carries a command",
            "agent_tab": "Copy Tab Link on an agent chat tab writes its chat's session link (kind session, no turn), "
                + "not a tab link; a new chat with no session has no link",
            "not_links": ["\(scheme)://\(DeepLink.authCallbackHost) is the sign-in callback, never a link"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text + "\n"
    }
}
