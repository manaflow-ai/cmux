import Foundation

/// What Settings > Server shows: a row per server the app heard from, built from the same
/// handshakes as the restart toast. Reading it never restarts anything.
public nonisolated struct ServerSettingsReport: Sendable, Equatable {
    /// The rows, cmux-tui before acpmux, this Mac before paired hosts.
    public var rows: [ServerSettingsRow]

    /// The card's fixed texts, localized.
    public struct Labels: Sendable, Equatable {
        /// "Server".
        public var title = UpdaterStrings.text("server.settings.card.title", "Server")
        /// Shown while no server has answered.
        public var empty = UpdaterStrings.text("server.settings.card.empty", "No server has answered yet.")
        /// "Local Socket".
        public var socket = UpdaterStrings.text("server.settings.card.socket", "Local Socket")
        /// "Tailscale Address".
        public var tailnet = UpdaterStrings.text("server.settings.card.tailnet", "Tailscale Address")
        /// "Copy".
        public var copy = UpdaterStrings.text("server.settings.card.copy", "Copy")
        /// "Pair".
        public var pair = UpdaterStrings.text("server.settings.card.pair", "Pair")

        /// The texts in the current language.
        public init() {}
    }

    /// The card's fixed texts.
    public var labels = Labels()

    /// - Parameter rows: The rows, in display order.
    public init(rows: [ServerSettingsRow]) {
        self.rows = rows
    }

    /// One row from a handshake and the notice a restart would answer (nil: nothing to gain).
    static func row(handshake: ServerHandshake, notice: ServerUpdateNotice?, socketPath: String?,
                    tailnetAddress: String?) -> ServerSettingsRow {
        let label = ServerUpdateNotice(kind: handshake.kind, host: handshake.host, serverBuild: nil,
                                       missingCapabilities: [], gainedFeatures: [],
                                       impact: ServerRestartImpact(kind: handshake.kind, keepsWork: true)).serverLabel
        let local = handshake.host == .local
        return ServerSettingsRow(
            kind: handshake.kind, host: handshake.host, name: label, isRunning: true,
            statusText: UpdaterStrings.text("server.settings.status.running", "Running"),
            versionLine: versionLine(handshake),
            restart: notice.map { restart(for: $0) },
            socketPath: local ? socketPath : nil, tailnetAddress: local ? tailnetAddress : nil)
    }

    private static func versionLine(_ handshake: ServerHandshake) -> String {
        var parts: [String] = []
        if let version = handshake.version {
            parts.append(UpdaterStrings.format("server.settings.version", "Version %@", version))
        }
        if let build = handshake.build {
            parts.append(UpdaterStrings.format("server.settings.build", "Build %@", build))
        }
        if let protocolVersion = handshake.protocolVersion {
            parts.append(UpdaterStrings.format("server.settings.protocol", "Protocol %lld", Int64(protocolVersion)))
        }
        return parts.joined(separator: " · ")
    }

    private static func restart(for notice: ServerUpdateNotice) -> ServerSettingsRow.Restart {
        let named = notice.gainedFeatures.prefix(ServerUpdateNotice.namedLimit).map(\.title)
        let more = notice.missingCapabilities.count - named.count
        let help: String
        if named.isEmpty {
            help = UpdaterStrings.text("server.settings.restart.older", "This server runs an older build than the app.")
        } else if more > 0 {
            help = UpdaterStrings.format("server.settings.restart.featuresMore", "A restart turns on: %1$@ and %2$lld more",
                                         named.joined(separator: UpdaterStrings.text("server.list.separator", ", ")), Int64(more))
        } else {
            help = UpdaterStrings.format("server.settings.restart.features", "A restart turns on: %@",
                                         ListFormatter.localizedString(byJoining: named))
        }
        return ServerSettingsRow.Restart(
            kind: notice.kind, host: notice.host,
            title: UpdaterStrings.text("server.settings.restart.title", "Restart Recommended"),
            help: help, buttonTitle: notice.restartButtonTitle)
    }
}
