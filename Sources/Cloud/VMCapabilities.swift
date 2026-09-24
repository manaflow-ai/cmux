import CmuxSurfaceCatalogModel
import Foundation

/// What a machine's provider can do; the app offers only verbs that can succeed
/// (Checkpoint/Fork disappear from menus when false — a verb that answers 502
/// "not implemented" is not a verb).
struct VMCapabilities: Equatable, Sendable {
    var snapshot: Bool
    var restore: Bool
    var fork: Bool
    var exec: Bool
    var stats: Bool
    /// The provider can mint a browser preview URL for a machine port.
    var ports: Bool
    var desktop: Bool
    var sizing: Bool
    var persistentHome: Bool
    var attachTransports: [String]?

    var ssh: Bool { attachTransports?.contains("ssh") ?? true }
    var cmuxRemote: Bool { attachTransports?.contains("cmux-remote") ?? true }

    static let all = VMCapabilities(
        snapshot: true, restore: true, fork: true,
        exec: true, stats: true, ports: true, desktop: true,
        sizing: true, persistentHome: true, attachTransports: nil)

    init(
        snapshot: Bool, restore: Bool, fork: Bool,
        exec: Bool = true, stats: Bool = true, ports: Bool = true,
        desktop: Bool = true, sizing: Bool = true, persistentHome: Bool = true,
        attachTransports: [String]? = nil
    ) {
        self.snapshot = snapshot
        self.restore = restore
        self.fork = fork
        self.exec = exec
        self.stats = stats
        self.ports = ports
        self.desktop = desktop
        self.sizing = sizing
        self.persistentHome = persistentHome
        self.attachTransports = attachTransports
    }

    /// Missing flags preserve legacy support; stats can use the historical kind fallback.
    init(json: Any?, legacyStatsSupported: Bool = true) {
        let dict = json as? [String: Any]
        func flag(_ key: String, fallback: Bool = true) -> Bool {
            if let value = dict?[key] as? Bool { return value }
            if let number = dict?[key] as? NSNumber { return number.boolValue }
            return fallback
        }
        let transports = (dict?["attachTransports"] as? [Any] ?? dict?["attach_transports"] as? [Any])?
            .compactMap { $0 as? String }
        self.init(
            snapshot: flag("snapshot"), restore: flag("restore"), fork: flag("fork"),
            exec: flag("exec"), stats: flag("stats", fallback: legacyStatsSupported), ports: flag("ports"),
            desktop: flag("desktop"), sizing: flag("sizing"),
            persistentHome: flag("persistentHome"), attachTransports: transports)
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "snapshot": snapshot, "restore": restore, "fork": fork,
            "exec": exec, "stats": stats, "ports": ports, "desktop": desktop,
            "sizing": sizing, "persistentHome": persistentHome,
        ]
        if let attachTransports { object["attach_transports"] = attachTransports }
        return object
    }

    init(vmResponse: [String: Any]) {
        let kind = VMMachineKind.resolved(kind: vmResponse["kind"], image: vmResponse["image"])
        self.init(json: vmResponse["capabilities"], legacyStatsSupported: kind.hasDesktop)
    }
}
