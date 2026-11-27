public import CmuxNextDesign

/// Debug Settings declarations of the server UI (DEV and NIGHTLY only;
/// Release keeps the code defaults until Lawrence picks).
public nonisolated enum ServerTunables {
    public static let section = TunableSection(id: "server", title: "Server", symbol: "server.rack", order: 42)

    /// Lets **Make This Mac a Server** register the server LaunchAgent. Off by
    /// default: until the bundled `cmux` ships `cmux host run`, a registered
    /// agent exits and launchd restarts it. Stop Serving ignores it.
    public static let agentAllowRegister = Tunable<Bool>.toggle(
        "server.agent.allowRegister", section, "Allow server agent",
        help: "Make This Mac a Server registers the server LaunchAgent (cmux host run). Off until the server software ships.",
        default: false, code: "ServerTunables.agentAllowRegister")

    /// How the right sidebar's Machines section lays out its machines (``MachineSectionStyle``).
    public static let machinesStyle = Tunable<MachineSectionStyle>.choice(
        "machines.section.style", section, "Machines section",
        help: "How the right sidebar's Machines section groups its machines and how much each row says. Switches live.",
        default: .compact, code: "ServerTunables.machinesStyle")

    /// Sample machines in the Machines section, one of each kind and state, for comparing its layouts on
    /// a Mac with no remote machine (``MachineSectionRow/fixtures``).
    public static let machinesFixture = Tunable<Bool>.toggle(
        "machines.section.fixture", section, "Sample machines",
        help: "Adds sample Cloud, SSH and server machines (connected, connecting and offline) to the Machines section.",
        default: false, code: "ServerTunables.machinesFixture")

    public static var all: [TunableDescriptor] {
        [agentAllowRegister.descriptor,
         machinesStyle.descriptor, machinesFixture.descriptor]
    }
}
