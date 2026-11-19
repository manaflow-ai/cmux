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
        public var refresh: @MainActor () async -> Void
        public var startAging: @MainActor (AnyObject, @escaping @MainActor () -> Bool) -> Void
        public var stopAging: @MainActor (AnyObject) -> Void
        private var openConnected: @MainActor (String) -> Void
        private var openJoined: @MainActor (JoinedMachine) -> Void

        public init(rows: @escaping @MainActor () -> [MachineSectionRow],
                    add: @escaping @MainActor () -> Void,
                    openConnected: @escaping @MainActor (String) -> Void,
                    openJoined: @escaping @MainActor (JoinedMachine) -> Void,
                    refresh: @escaping @MainActor () async -> Void = {},
                    startAging: @escaping @MainActor (AnyObject, @escaping @MainActor () -> Bool) -> Void = { _, _ in },
                    stopAging: @escaping @MainActor (AnyObject) -> Void = { _ in }) {
            self.rows = rows
            self.add = add
            self.openConnected = openConnected
            self.openJoined = openJoined
            self.refresh = refresh
            self.startAging = startAging
            self.stopAging = stopAging
        }

        /// Mesh-only joined Macs use the signed-in dial flow; linked rows use the ordinary workspace action.
        public func open(_ machine: MachineSectionRow) {
            if let joined = machine.joined, machine.id == JoinedMachine.healthID(joined.id) {
                // A mesh-only joined row is a presence/management row. Only an online Mac
                // supports the signed-in dial flow; Linux and Windows rows have no daemon
                // machine id that workspace.newOnMachine could accept.
                if joined.state == .online, joined.isMac {
                    openJoined(joined)
                }
                return
            }
            if machine.isConnected {
                openConnected(machine.id)
            }
        }
    }

    private static let prefix = LayoutItemID.transientPrefix + "hosts:"
    private static let headerID = LayoutItemID(prefix + "header")
    private static let addID = LayoutItemID(prefix + "add")
    private static let rowPrefix = prefix + "row:"

    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var initialRefresh: Task<Void, Never>?
    public private(set) var expanded = true

    public init(host: Host? = nil) {
        self.host = host
        if let host {
            initialRefresh = Task { await host.refresh() }
            host.startAging(self) { true }
        }
    }

    public func bind(host: Host) {
        initialRefresh?.cancel()
        if let previous = self.host { previous.stopAging(self) }
        self.host = host
        initialRefresh = Task { await host.refresh() }
        host.startAging(self) { true }
    }

    deinit {
        initialRefresh?.cancel()
        host?.stopAging(self)
    }

    /// Rows are transient and therefore never become a second machine catalog or a durable layout item.
    public func rows() -> [SidebarTransientItem] {
        Self.rows(machines: host?.rows() ?? [], expanded: expanded)
    }

    /// Handles the header, Add Host and machine-row clicks. Returns false for another transient item.
    public func activate(_ id: LayoutItemID) -> Bool {
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
