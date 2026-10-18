import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextRemote
import Foundation

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
            ControlSessionNaming.Candidate(id: key(daemon), name: qualifierName(machine: name, session: sessionLabel(daemon)))
        })
        return zip(daemons, names).map { daemon, name in
            let id = key(daemon)
            return ControlSessionInfo(
                id: id, qualifier: qualifiers[id] ?? id, machineID: daemon.machineID, machineName: name,
                sessionName: daemon.identity?.session, isHome: daemon.isLocal, state: state(daemon.store.connectionState),
                transport: transport(daemon, machines: machines))
        }
    }

    /// The session name a qualifier shows: the daemon's own, except for this
    /// app's home session when the session is named by the build key
    /// (`cmux-app--<key hash>`, per-build isolation S3), which shows the
    /// build's bundle name (`cmux DEV`, `cmux STAGING x1`) or tag instead. The
    /// hash stays in the session id and `session_name`.
    static func sessionLabel(_ daemon: DaemonService) -> String? {
        let session = daemon.identity?.session
        guard daemon.isLocal, let home = homeSessionLabel, session == home.session else { return session }
        return home.label
    }

    /// This build's key-named app session and the label it shows; nil when
    /// the build keeps a tag or channel session name.
    static let homeSessionLabel: (session: String, label: String)? = {
        let build = LaunchIdentity.current().build
        guard !build.keepsAppNames, let session = build.appSession else { return nil }
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .trimmingCharacters(in: .whitespaces)
        guard let label = bundleName.flatMap({ $0.isEmpty ? nil : $0 }) ?? build.tag else { return nil }
        return (session, label)
    }()

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
    /// UTF-8 scans: it runs in every control snapshot publish (per tab switch).
    static func shortHost(_ name: String) -> String {
        let bytes = name.utf8
        if bytes.contains(UInt8(ascii: "/")) || bytes.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ":") }) {
            return name
        }
        // The first non-empty label, as `split(separator: ".").first`.
        guard let start = bytes.firstIndex(where: { $0 != UInt8(ascii: ".") }) else { return name }
        let end = bytes[start...].firstIndex(of: UInt8(ascii: ".")) ?? bytes.endIndex
        return start == bytes.startIndex && end == bytes.endIndex ? name : String(name[start..<end])
    }

    /// Session names that add nothing to a machine's name.
    static let defaultSessionNames: Set<String> = Set([RemoteSessionName.defaultName, "cmux-app"]
        + DaemonLauncher.channelBundleIDs.compactMap { try? DaemonLauncher.sessionName(tag: $0.1) })

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
