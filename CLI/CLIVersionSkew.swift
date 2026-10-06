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
            self.app = app
            self.version = version
            self.build = build
            self.cliPath = cliPath
            self.methods = methods
        }

        private static func text(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The product name this CLI belongs to, as `system.identify` reports it.
    static let cliProduct = "cmux"

    /// Rewrites an uncaught `method_not_found` into a version-skew error, or
    /// returns `error` unchanged when it is not one.
    static func diagnose(
        _ error: Error,
        client: SocketClient,
        cliVersion: String,
        cliShortVersion: String?,
        cliPath: String?
    ) -> Error {
        guard let failure = error as? CLIError,
              failure.isStructuredProtocolResponse,
              failure.v2Code == "method_not_found",
              let method = failure.v2Method,
              method != "system.identify" else {
            return error
        }
        let peer: Peer?
        do {
            peer = Peer(identify: try client.sendV2(method: "system.identify", responseTimeout: 2))
        } catch {
            peer = nil
        }
        guard let message = message(
            method: method,
            socketPath: client.socketPath,
            cliVersion: cliVersion,
            cliShortVersion: cliShortVersion,
            cliPath: cliPath,
            peer: peer,
            original: failure.message
        ) else {
            return error
        }
        return CLIError(
            message: message,
            exitCode: failure.exitCode,
            v2Code: failure.v2Code,
            isStructuredProtocolResponse: true,
            v2Method: method
        )
    }

    /// The user-facing explanation, or nil when the app is the same build as
    /// this CLI (or lists the method), so the original error already says it.
    static func message(
        method: String,
        socketPath: String,
        cliVersion: String,
        cliShortVersion: String?,
        cliPath: String?,
        peer: Peer?,
        original: String
    ) -> String? {
        if let methods = peer?.methods, methods.contains(method) { return nil }
        guard let details = details(cliVersion: cliVersion, cliShortVersion: cliShortVersion, cliPath: cliPath, peer: peer) else {
            return nil
        }
        let header = String(
            format: String(
                localized: "cli.versionSkew.header",
                defaultValue: "%1$@ is not supported by the app on %2$@. The CLI and the app come from different builds."
            ),
            locale: .current,
            method,
            socketPath
        )
        return ([header] + details + ["(\(original))"]).joined(separator: "\n")
    }

    /// The note `cmux <command> --help` appends when the app on the socket
    /// is another build, so the listed commands may not all work there. Nil
    /// when the builds match or the app cannot be identified.
    static func helpNote(
        socketPath: String,
        cliVersion: String,
        cliShortVersion: String?,
        cliPath: String?
    ) -> String? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        let identify: [String: Any]
        do {
            try client.connect(deadline: Date.now.addingTimeInterval(0.3))
            identify = try client.sendV2(method: "system.identify", responseTimeout: 0.3)
        } catch {
            return nil
        }
        guard let details = details(
            cliVersion: cliVersion,
            cliShortVersion: cliShortVersion,
            cliPath: cliPath,
            peer: Peer(identify: identify)
        ) else { return nil }
        let header = String(
            format: String(
                localized: "cli.versionSkew.helpHeader",
                defaultValue: "Note: the app on %@ is a different build from this CLI. Some commands above may not work there."
            ),
            locale: .current,
            socketPath
        )
        return ([header] + details).joined(separator: "\n")
    }

    /// The CLI line, app line, and fix, or nil when there is no skew.
    private static func details(
        cliVersion: String,
        cliShortVersion: String?,
        cliPath: String?,
        peer: Peer?
    ) -> [String]? {
        let otherProduct = peer?.app.map { $0 != cliProduct } ?? false
        let order = compare(cliShortVersion, peer?.version)
        if !otherProduct, order == .orderedSame { return nil }

        let cliLine = cliPath.map { "\(cliVersion) (\($0))" } ?? cliVersion
        var lines = [
            "  " + String(
                format: String(localized: "cli.versionSkew.cliLine", defaultValue: "This CLI: %@"),
                locale: .current,
                cliLine
            ),
            "  " + String(
                format: String(localized: "cli.versionSkew.appLine", defaultValue: "Connected app: %@"),
                locale: .current,
                appDescription(peer)
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
                        defaultValue: "This socket belongs to %1$@, which has its own CLI. Run %2$@, or put its directory first on PATH."
                    ),
                    locale: .current,
                    app,
                    peerCLI
                )
            } else {
                fix = String(
                    format: String(
                        localized: "cli.versionSkew.fix.otherProductNoPath",
                        defaultValue: "This socket belongs to %@, which has its own CLI. Run the cmux CLI inside that app's bundle (Contents/Resources/bin/cmux)."
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
                    defaultValue: "This CLI is older than the app. Run the app's CLI, %@, or remove the older cmux from PATH."
                ),
                locale: .current,
                peerCLI ?? "Contents/Resources/bin/cmux"
            )
        } else {
            // The app is older, or does not report a version (apps before
            // 0.65 do not): usually an installed update waiting for a relaunch.
            fix = String(
                localized: "cli.versionSkew.fix.appOlder",
                defaultValue: "The running app is older than this CLI. Quit and reopen cmux to finish an installed update, or update it with cmux > Check for Updates."
            )
        }
        lines.append(String(
            format: String(localized: "cli.versionSkew.fixLine", defaultValue: "Fix: %@"),
            locale: .current,
            fix
        ))
        return lines
    }

    private static func appDescription(_ peer: Peer?) -> String {
        guard let peer else {
            return String(
                localized: "cli.versionSkew.app.unknown",
                defaultValue: "unknown (it does not answer system.identify)"
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
                    defaultValue: "%@, a build that does not report its version"
                ),
                locale: .current,
                name
            )
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
