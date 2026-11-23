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
    public struct Scheme: Sendable, Hashable, Codable {
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

    /// The export as pretty-printed, key-sorted JSON (a trailing newline).
    public func json() -> String {
        var request = DeepLinkRust.Request("export")
        request.schemes = schemes
        return DeepLinkRust.call(request, as: String.self) ?? ""
    }
}
