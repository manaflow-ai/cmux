import Foundation

/// Explains a `method_not_found` answer that reaches the user.
///
/// The CLI and the app it talks to can come from different builds: the app
/// bundle was updated on disk but the running app was not relaunched, a
/// `cmux` earlier on `PATH` belongs to another install, or the socket belongs
/// to a different cmux app (cmux-next answers with its own method set). A bare
/// `method_not_found: Unknown method` hides all of that. Callers that probe
/// for optional methods catch `method_not_found` before it gets here, so this
/// runs only for errors the CLI is about to print.
///
/// This file has no socket dependency so unit tests can compile it; the
/// socket round trip lives in `CLIVersionSkew+Diagnose.swift`.
enum CLIVersionSkew {
    /// What the connected app says about itself in `system.identify`.
    struct Peer: Equatable {
        /// `app` from `system.identify` (`cmux`, `cmux-next`); nil from apps
        /// that predate the field.
        var app: String?
        var version: String?
        var build: String?
        var cliPath: String?
        /// Methods the app lists, when it lists them.
        var methods: [String]?

        init(identify: [String: Any]) {
            app = Self.text(identify["app"])
            version = Self.text(identify["version"])
            build = Self.text(identify["build"])
            cliPath = Self.text(identify["app_cli_path"])
            methods = identify["methods"] as? [String]
        }

        init(app: String?, version: String?, build: String?, cliPath: String?, methods: [String]? = nil) {
            self.app = Self.text(app)
            self.version = Self.text(version)
            self.build = Self.text(build)
            self.cliPath = Self.text(cliPath)
            self.methods = methods
        }

        private static func text(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = CLITerminalText.printable(string).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The product name this CLI belongs to, as `system.identify` reports it.
    static let cliProduct = "cmux"

    /// The user-facing explanation, or nil when the original error already
    /// says enough: the app is the same build as this CLI, lists the method,
    /// or this CLI cannot read its own version. `bundle` selects the string
    /// table (nil is the main bundle); tests pass one without a table to get
    /// the English source text on any system language.
    static func message(
        method: String,
        socketPath: String,
        cliVersion: String,
        cliShortVersion: String?,
        cliBuild: String? = nil,
        cliPath: String?,
        peer: Peer?,
        original: String,
        bundle: Bundle? = nil
    ) -> String? {
        if let methods = peer?.methods, methods.contains(method) { return nil }
        guard let details = details(
            cliVersion: cliVersion,
            cliShortVersion: cliShortVersion,
            cliBuild: cliBuild,
            cliPath: cliPath,
            peer: peer,
            bundle: bundle
        ) else {
            return nil
        }
        let header = String(
            format: String(
                localized: "cli.versionSkew.header",
                defaultValue: "%1$@ is not supported by the app on %2$@. The CLI and the app come from different builds.",
                bundle: bundle
            ),
            locale: .current,
            method,
            socketPath
        )
        return ([header] + details + ["(\(CLITerminalText.printable(original.replacingOccurrences(of: "\n", with: " "))))"]).joined(separator: "\n")
    }

    /// The CLI line, app line, and fix, or nil when there is no skew or this
    /// CLI cannot read its own version to tell.
    private static func details(
        cliVersion: String,
        cliShortVersion: String?,
        cliBuild: String?,
        cliPath: String?,
        peer: Peer?,
        bundle: Bundle?
    ) -> [String]? {
        let otherProduct = peer?.app.map { $0 != cliProduct } ?? false
        let order = versionOrder(
            cliShortVersion: cliShortVersion,
            cliBuild: cliBuild,
            peerVersion: peer?.version,
            peerBuild: peer?.build
        )
        if !otherProduct {
            // Without its own version this CLI cannot tell a skew from a
            // same-build error, so the original error stands.
            if components(cliShortVersion) == nil || order == .orderedSame { return nil }
        }

        let cliLine = cliPath.map { "\(cliVersion) (\($0))" } ?? cliVersion
        var lines = [
            "  " + String(
                format: String(localized: "cli.versionSkew.cliLine", defaultValue: "This CLI: %@", bundle: bundle),
                locale: .current,
                cliLine
            ),
            "  " + String(
                format: String(localized: "cli.versionSkew.appLine", defaultValue: "Connected app: %@", bundle: bundle),
                locale: .current,
                appDescription(peer, bundle: bundle)
            ),
        ]

        let fix: String
        let peerCLI = peer?.cliPath.flatMap { $0 == cliPath ? nil : $0 }
        if otherProduct {
            let app = peer?.app ?? ""
            if let peerCLI {
                fix = String(
                    format: String(
                        localized: "cli.versionSkew.fix.otherProduct",
                        defaultValue: "This socket belongs to %1$@, which has its own CLI. Run %2$@, or put its directory first on PATH.",
                        bundle: bundle
                    ),
                    locale: .current,
                    app,
                    peerCLI
                )
            } else {
                fix = String(
                    format: String(
                        localized: "cli.versionSkew.fix.otherProductNoPath",
                        defaultValue: "This socket belongs to %@, which has its own CLI. Run the cmux CLI inside that app's bundle (Contents/Resources/bin/cmux).",
                        bundle: bundle
                    ),
                    locale: .current,
                    app
                )
            }
        } else if order == .orderedAscending {
            // The app is newer than this CLI: an older `cmux` is earlier on PATH.
            fix = String(
                format: String(
                    localized: "cli.versionSkew.fix.cliOlder",
                    defaultValue: "This CLI is older than the app. Run the app's CLI, %@, or remove the older cmux from PATH.",
                    bundle: bundle
                ),
                locale: .current,
                peerCLI ?? "Contents/Resources/bin/cmux"
            )
        } else if order == .orderedDescending || (peer != nil && peer?.app == nil && peer?.version == nil) {
            // The app is older, or answers identify without `app` and
            // `version` (both arrived together, so it predates them):
            // usually an installed update waiting for a relaunch.
            fix = String(
                localized: "cli.versionSkew.fix.appOlder",
                defaultValue: "The running app is older than this CLI. Quit and reopen cmux to finish an installed update, or update it with cmux > Check for Updates.",
                bundle: bundle
            )
        } else {
            // identify failed or returned a version this CLI cannot parse:
            // the direction of the skew is unknown, so do not guess it.
            fix = String(
                localized: "cli.versionSkew.fix.unknown",
                defaultValue: "Could not read the app's version. Compare it in cmux > About cmux with this CLI, then relaunch or update the older one.",
                bundle: bundle
            )
        }
        lines.append(String(
            format: String(localized: "cli.versionSkew.fixLine", defaultValue: "Fix: %@", bundle: bundle),
            locale: .current,
            fix
        ))
        return lines
    }

    private static func appDescription(_ peer: Peer?, bundle: Bundle?) -> String {
        guard let peer else {
            return String(
                localized: "cli.versionSkew.app.unknown",
                defaultValue: "unknown (it does not answer system.identify)",
                bundle: bundle
            )
        }
        let name = peer.app ?? cliProduct
        switch (peer.version, peer.build) {
        case let (version?, build?):
            return "\(name) \(version) (\(build))"
        case let (version?, nil):
            return "\(name) \(version)"
        default:
            return String(
                format: String(
                    localized: "cli.versionSkew.app.noVersion",
                    defaultValue: "%@, a build that does not report its version",
                    bundle: bundle
                ),
                locale: .current,
                name
            )
        }
    }

    /// Orders this CLI against the app: by short version, then by build when
    /// the short versions match and both sides report a build (nightlies and
    /// dev builds share a short version). Builds that are equal, missing on
    /// either side, or not purely numeric fall back to the short-version result, so
    /// an unknown build never invents a skew. Different numeric builds with no
    /// clear order (`1.2` vs `1.2.0`) compare as the same.
    static func versionOrder(
        cliShortVersion: String?,
        cliBuild: String?,
        peerVersion: String?,
        peerBuild: String?
    ) -> ComparisonResult? {
        let byVersion = compare(cliShortVersion, peerVersion)
        guard byVersion == .orderedSame,
              let cliBuild, let peerBuild, cliBuild != peerBuild,
              isNumericBuild(cliBuild), isNumericBuild(peerBuild),
              let byBuild = compare(cliBuild, peerBuild) else {
            return byVersion
        }
        return byBuild
    }

    /// A build is comparable only when it is dotted digits and nothing else.
    /// `compare` drops `-dev` style suffixes, which is right for short
    /// versions but would order `108-dev` against `109` by guesswork.
    private static func isNumericBuild(_ build: String) -> Bool {
        let parts = build.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// Compares dotted numeric versions (`0.64.25` < `0.65.0`). An unknown
    /// side compares as unordered (`nil`).
    static func compare(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        let core = version.split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? version
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }
}
