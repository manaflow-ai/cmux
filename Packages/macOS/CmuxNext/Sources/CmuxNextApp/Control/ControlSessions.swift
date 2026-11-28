import CmuxNextControl
import CmuxNextDaemon
import CmuxNextRemote

/// The sessions the control socket names (plans/cmux-next/data-model.md
/// 1.1 and 1.3): the home session (the local daemon) and every remote one,
/// with the unique qualifier that prefixes a remote session's object ids.
@MainActor
enum ControlSessions {
    /// The stable key of `daemon`'s session: its `registry_id`, or the App
    /// machine id until the daemon reported one.
    static func key(_ daemon: DaemonService) -> String {
        daemon.identity?.sessionID ?? "machine:\(daemon.machineID)"
    }

    static func sessions(machines: MachineRegistry) -> [ControlSessionInfo] {
        let daemons = machines.daemons
        let names = daemons.map { machineName($0, machines: machines) }
        let qualifiers = ControlSessionNaming.shared.qualifiers(zip(daemons, names).map { daemon, name in
            ControlSessionNaming.Candidate(id: key(daemon), name: qualifierName(machine: name, session: daemon.identity?.session))
        })
        return zip(daemons, names).map { daemon, name in
            let id = key(daemon)
            return ControlSessionInfo(
                id: id, qualifier: qualifiers[id] ?? id, machineID: daemon.machineID, machineName: name,
                sessionName: daemon.identity?.session, isHome: daemon.isLocal, state: state(daemon.store.connectionState),
                transport: transport(daemon, machines: machines))
        }
    }

    static func transport(_ daemon: DaemonService, machines: MachineRegistry) -> String {
        if daemon.isLocal { return "local" }
        if machines.sshSession(daemon.machineID) != nil { return "ssh" }
        return machines.server(daemon.machineID) != nil ? "server" : "cloud"
    }

    /// `build-box`, or `build-box-ci` for session `ci` on it: the machine
    /// name plus the session name when that is not a default one
    /// (plans/cmux-next/data-model.md 1.1).
    static func qualifierName(machine rawMachine: String?, session: String?) -> String? {
        let machine = rawMachine.map(shortHost)
        guard let session, !session.isEmpty, !defaultSessionNames.contains(session) else { return machine ?? session }
        guard let machine else { return session }
        // An SSH label already names its session (`host/session`).
        return machine.hasSuffix("/" + session) ? machine : "\(machine)-\(session)"
    }

    /// A host name's first DNS label (`cmux-dev-backend-1` for
    /// `cmux-dev-backend-1.us-central1-b.c.example.internal`); an IP address
    /// or an SSH label (`host/session`) stays whole.
    static func shortHost(_ name: String) -> String {
        if name.contains("/") || name.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return name }
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    /// Session names that add nothing to a machine's name.
    static let defaultSessionNames: Set<String> = [RemoteSessionName.defaultName, "cmux-app"]

    /// The host name the daemon reports, else the App's name for a remote
    /// machine (SSH label, Cloud title).
    static func machineName(_ daemon: DaemonService, machines: MachineRegistry) -> String? {
        daemon.identity?.machineName ?? machines.machineName(daemon.machineID)
    }

    static func state(_ state: DaemonConnectionState) -> String {
        switch state {
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        }
    }
}
