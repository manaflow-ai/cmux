public import CmuxNextDesign

/// Debug Settings declarations of the server UI (DEV and NIGHTLY only;
/// Release keeps the code defaults until Lawrence picks).
public nonisolated enum ServerTunables {
    public static let section = TunableSection(id: "server", title: "Server", symbol: "server.rack", order: 42)

    public static let panelStyle = Tunable<ServerPanelStyle>.choice(
        "server.panel.style", section, "Menubar panel", help: "Prototype layout of the server menubar panel. Switches live.",
        default: .compact, code: "ServerTunables.panelStyle")

    public static let pairingStyle = Tunable<ServerPairingStyle>.choice(
        "server.pairing.style", section, "Pairing", help: "What the server shows while it waits for approval. Switches live.",
        default: .code, code: "ServerTunables.pairingStyle")

    public static let healthStyle = Tunable<ServerHealthStyle>.choice(
        "server.health.style", section, "Health", help: "Prototype layout of the server Health view. Switches live.",
        default: .checklist, code: "ServerTunables.healthStyle")

    public static var all: [TunableDescriptor] { [panelStyle.descriptor, pairingStyle.descriptor, healthStyle.descriptor] }
}
