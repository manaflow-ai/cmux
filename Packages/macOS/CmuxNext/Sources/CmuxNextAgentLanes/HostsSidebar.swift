import CmuxNextCompat
public import CmuxNextServer
public import CmuxNextSidebar
import Foundation
public import Observation

/// The native Hosts section. It consumes the same `MachineSectionRow.rows` snapshot as the Machines
/// page, so the sidebar and page cannot disagree about identity, ordering or connection state.
@Observable @MainActor
public final class HostsSidebar {
    public struct Host {
        public var rows: @MainActor () -> [MachineSectionRow]
        public var add: @MainActor () -> Void
        /// `labs.hostsSidebar`: off, the section and the remote-machine groups draw nothing and take no clicks.
        public var enabled: @MainActor () -> Bool
        private var openConnected: @MainActor (String) -> Void
        private var openJoined: @MainActor (JoinedMachine) -> Void

        public init(rows: @escaping @MainActor () -> [MachineSectionRow],
                    add: @escaping @MainActor () -> Void,
                    openConnected: @escaping @MainActor (String) -> Void,
                    openJoined: @escaping @MainActor (JoinedMachine) -> Void,
                    enabled: @escaping @MainActor () -> Bool = { true }) {
            self.rows = rows
            self.enabled = enabled
            self.add = add
            self.openConnected = openConnected
            self.openJoined = openJoined
        }

        /// Mesh-only joined Macs use the signed-in dial flow; linked rows use the ordinary workspace action.
        public func open(_ machine: MachineSectionRow) {
            if let joined = machine.joined, machine.id == JoinedMachine.healthID(joined.id),
               joined.state == .online, joined.isMac {
                openJoined(joined)
            } else if machine.isConnected {
                openConnected(machine.id)
            }
        }
    }

    private static let prefix = LayoutItemID.transientPrefix + "hosts:"
    private static let headerID = LayoutItemID(prefix + "header")
    private static let addID = LayoutItemID(prefix + "add")
    private static let rowPrefix = prefix + "row:"

    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var labsWatch: Task<Void, Never>?
    public private(set) var expanded = true

    public init(host: Host? = nil) { self.host = host }

    public func bind(host: Host) { self.host = host }

    public var isEnabled: Bool { host?.enabled() == true }

    /// Rows are transient and therefore never become a second machine catalog or a durable layout item.
    public func rows() -> [SidebarTransientItem] {
        guard isEnabled else { return [] }
        return Self.rows(machines: host?.rows() ?? [], expanded: expanded)
    }

    /// The Hosts rows, then `remote`'s groups; none while the switch is off (Lawrence 2026-10-26: other
    /// machines' chats are not top-band rows by default).
    public func topItems(remote: RemoteMachinesSidebar?) -> [SidebarTransientItem] {
        guard isEnabled else { return [] }
        return rows() + (remote?.rows() ?? [])
    }

    /// A click on a Hosts row or a remote group's row; false while the switch is off.
    public func activate(_ id: LayoutItemID, remote: RemoteMachinesSidebar) -> Bool {
        isEnabled && (activate(id) || remote.activate(id))
    }

    /// Binds `remote` (through `bind`) while the switch is on and stops it when it turns off, so with the
    /// switch off the groups read no peers and follow no lanes, as before it existed.
    public func follow(remote: RemoteMachinesSidebar, bind: @escaping @MainActor () -> Void) {
        labsWatch?.cancel()
        // task-owner: this instance (`stop`); event-driven (Observation)
        labsWatch = Task { [weak self] in
            for await on in ObservationStream({ [weak self] in self?.isEnabled == true }) {
                if on { bind() } else { remote.stop() }
            }
        }
    }

    public func stop() {
        labsWatch?.cancel()
        labsWatch = nil
    }

    /// Handles the header, Add Host and machine-row clicks. Returns false for another transient item.
    public func activate(_ id: LayoutItemID) -> Bool {
        guard isEnabled else { return false }
        let raw = id.rawValue
        if raw == Self.headerID.rawValue {
            expanded.toggle()
            return true
        }
        if raw == Self.addID.rawValue {
            host?.add()
            return true
        }
        guard let machineID = raw.hasPrefix(Self.rowPrefix) ? String(raw.dropFirst(Self.rowPrefix.count)) : nil,
              let machine = host?.rows().first(where: { $0.id == machineID }) else { return false }
        host?.open(machine)
        return true
    }

    @MainActor
    static func rows(machines: [MachineSectionRow], expanded: Bool) -> [SidebarTransientItem] {
        var items: [SidebarTransientItem] = []
        var previous: [LayoutItemRef] = [.app("cmux/app-store"), SidebarTransientItem.channels.item.ref,
                                          SidebarLayoutDocument.homeRef, .builtIn(.home)]
        func add(_ id: LayoutItemID, _ info: SidebarItemInfo) {
            items.append(SidebarTransientItem(id: id, info: info, after: previous))
            previous = [LayoutItemRef(kind: "client", value: id.rawValue)]
        }

        var header = SidebarItemInfo(title: "Hosts", symbol: "server.rack", badge: machines.isEmpty ? nil : machines.count)
        header.activity = machines.contains(where: { $0.isConnecting }) ? .working : .idle
        add(Self.headerID, header)
        guard expanded else { return items }

        var addHost = SidebarItemInfo(title: "Add Host…", symbol: "plus")
        addHost.caption = "Add Host…"
        addHost.indent = 1
        add(Self.addID, addHost)
        for machine in machines {
            var info = SidebarItemInfo(title: machine.name, symbol: symbol(for: machine))
            info.caption = caption(for: machine)
            info.indent = 1
            info.isMissing = !machine.isConnected && !machine.isConnecting && machine.serverState == nil
            info.activity = machine.isConnecting ? .working : .idle
            add(LayoutItemID(Self.rowPrefix + machine.id), info)
        }
        return items
    }

    private static func symbol(for machine: MachineSectionRow) -> String {
        if let symbol = machine.symbol { return symbol }
        return switch machine.kind {
        case .local: "laptopcomputer"
        case .cloud: "cloud"
        case .ssh: "terminal"
        case .server, .joined: "server.rack"
        }
    }

    private static func caption(for machine: MachineSectionRow) -> String {
        if let state = machine.serverState {
            switch state {
            case .paused: return "Paused"
            case .resuming: return "Resuming…"
            case .failed: return "Failed"
            case .deleted: return "Deleted"
            }
        }
        if machine.isConnecting { return "Connecting…" }
        return machine.isConnected ? "Connected" : "Offline"
    }
}
