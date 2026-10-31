import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

/// The wire form of a ``ServerSettingsReport`` for the Settings page: `server` in the host lists.
struct ServerSettingsPageJSON {
    let report: ServerSettingsReport

    var json: JSONValue {
        [
            "title": .string(report.labels.title), "empty": .string(report.labels.empty),
            "socket_title": .string(report.labels.socket), "tailnet_title": .string(report.labels.tailnet),
            "copy_title": .string(report.labels.copy), "pair_title": .string(report.labels.pair),
            "servers": .array(report.rows.map(row)),
        ]
    }

    private func row(_ row: ServerSettingsRow) -> JSONValue {
        var host = JSONValue.null
        if case .remote(let name) = row.host { host = .string(name) }
        return [
            "id": .string(row.id), "kind": .string(row.kind.rawValue), "host": host,
            "name": .string(row.name), "running": .bool(row.isRunning), "status": .string(row.statusText),
            "version_line": .string(row.versionLine),
            "restart": row.restart.map { restart in
                [
                    "title": .string(restart.title), "help": .string(restart.help),
                    "button": .string(restart.buttonTitle),
                ] as JSONValue
            } ?? .null,
            "socket": row.socketPath.map(JSONValue.string) ?? .null,
            "tailnet": row.tailnetAddress.map(JSONValue.string) ?? .null,
        ]
    }
}
