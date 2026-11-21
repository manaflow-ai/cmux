public import CmuxNextServer
public import CmuxNextSidebar
import CmuxNextCompat
import Foundation
public import Observation

/// The native Hosts section. It consumes the same `MachineSectionRow.rows` snapshot as the Machines
/// page, so the sidebar and page cannot disagree about identity, ordering or connection state.
@Observable @MainActor
public final class HostsSidebar {
    public struct Host {
        public var rows: @MainActor () -> [MachineSectionRow]
        public var add: @MainActor () -> Void
        /// Whether this transient section is enabled by the person's Labs setting.
        public var enabled: @MainActor () -> Bool
        public var joined: JoinedMachineStore?
        public var refresh: @MainActor () async -> Void
        public var startAging: @MainActor (AnyObject, @escaping @MainActor () -> Bool) -> Void
        public var stopAging: @MainActor (AnyObject) -> Void
        private var openConnected: @MainActor (String) -> Void
        private var openJoined: @MainActor (JoinedMachine) -> Void
        private var openOffline: @MainActor (MachineSectionRow) -> Void

        public init(rows: @escaping @MainActor () -> [MachineSectionRow],
                    add: @escaping @MainActor () -> Void,
                    openConnected: @escaping @MainActor (String) -> Void,
                    openJoined: @escaping @MainActor (JoinedMachine) -> Void,
                    openOffline: @escaping @MainActor (MachineSectionRow) -> Void = { _ in },
                    joined: JoinedMachineStore? = nil,
                    enabled: @escaping @MainActor () -> Bool = { true }) {
            self.init(rows: rows, add: add, openConnected: openConnected, openJoined: openJoined,
                      openOffline: openOffline, joined: joined, enabled: enabled, refresh: { }, startAging: { _, _ in }, stopAging: { _ in })
        }

        public init(rows: @escaping @MainActor () -> [MachineSectionRow],
                    add: @escaping @MainActor () -> Void,
                    openConnected: @escaping @MainActor (String) -> Void,
                    openJoined: @escaping @MainActor (JoinedMachine) -> Void,
                    openOffline: @escaping @MainActor (MachineSectionRow) -> Void = { _ in },
                    joined: JoinedMachineStore? = nil,
                    enabled: @escaping @MainActor () -> Bool = { true },
                    refresh: @escaping @MainActor () async -> Void,
                    startAging: @escaping @MainActor (AnyObject, @escaping @MainActor () -> Bool) -> Void,
                    stopAging: @escaping @MainActor (AnyObject) -> Void) {
            self.rows = rows
            self.add = add
            self.enabled = enabled
            self.joined = joined
            self.openConnected = openConnected
            self.openJoined = openJoined
            self.openOffline = openOffline
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
            } else {
                openOffline(machine)
            }
        }
    }

    private static let prefix = LayoutItemID.transientPrefix + "hosts:"
    private static let headerID = LayoutItemID(prefix + "header")
    private static let addID = LayoutItemID(prefix + "add")
    private static let rowPrefix = prefix + "row:"

    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var initialRefresh: Task<Void, Never>?
    @ObservationIgnored private var enabledWatch: Task<Void, Never>?
    @ObservationIgnored private var visible: @MainActor () -> Bool = { true }
    @ObservationIgnored private var running = false
    public private(set) var expanded = true

    public init(host: Host? = nil, visible: @escaping @MainActor () -> Bool = { true }) {
        self.host = host
        self.visible = visible
        if let host {
            start(host, visible: visible)
            watch()
        }
    }

    public func bind(host: Host, visible: @escaping @MainActor () -> Bool = { true }) {
        enabledWatch?.cancel()
        initialRefresh?.cancel()
        initialRefresh = nil
        if let previous = self.host { stop(previous) }
        self.host = host
        self.visible = visible
        start(host, visible: visible)
        watch()
    }

    private func watch() {
        enabledWatch = Task { [weak self] in
            for await enabled in ObservationStream({ [weak self] in self?.host?.enabled() == true }) {
                guard let self, !Task.isCancelled, let host = self.host else { return }
                if enabled {
                    if !self.running { self.start(host, visible: self.visible) }
                } else if self.running {
                    self.initialRefresh?.cancel()
                    self.initialRefresh = nil
                    self.stop(host)
                }
            }
        }
    }

    public func stop() {
        enabledWatch?.cancel()
        enabledWatch = nil
        initialRefresh?.cancel()
        initialRefresh = nil
        if let host { stop(host) }
        host = nil
    }

    /// The Labs switch is read by the owning section so remote work can stop immediately when it turns off.
    public var isEnabled: Bool { host?.enabled() == true }

    nonisolated deinit {
        enabledWatch?.cancel()
        initialRefresh?.cancel()
    }

    private func start(_ host: Host, visible: @escaping @MainActor () -> Bool) {
        guard host.enabled() else { return }
        running = true
        if let joined = host.joined {
            initialRefresh = Task { guard !Task.isCancelled, host.enabled() else { return }; await joined.refresh() }
            joined.startAging(self, visible: visible)
        } else {
            initialRefresh = Task { guard !Task.isCancelled, host.enabled() else { return }; await host.refresh() }
            host.startAging(self, visible)
        }
    }

    private func stop(_ host: Host) {
        guard running else { return }
        running = false
        if let joined = host.joined { joined.stopAging(self) } else { host.stopAging(self) }
    }

    /// Rows are transient and therefore never become a second machine catalog or a durable layout item.
    public func rows() -> [SidebarTransientItem] {
        guard let host else { return [] }
        guard host.enabled() else {
            if initialRefresh != nil {
                initialRefresh?.cancel()
                initialRefresh = nil
                stop(host)
            }
            return []
        }
        if initialRefresh == nil { start(host, visible: visible) }
        return Self.rows(machines: host.rows(), expanded: expanded)
    }

    /// Handles the header, Add Host and machine-row clicks. Returns false for another transient item.
    public func activate(_ id: LayoutItemID) -> Bool {
        guard let host, host.enabled() else { return false }
        let raw = id.rawValue
        if raw == Self.headerID.rawValue {
            expanded.toggle()
            return true
        }
        if raw == Self.addID.rawValue {
            host.add()
            return true
        }
        guard let machineID = raw.hasPrefix(Self.rowPrefix) ? String(raw.dropFirst(Self.rowPrefix.count)) : nil,
              let machine = host.rows().first(where: { $0.id == machineID }) else { return false }
        host.open(machine)
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

        var header = SidebarItemInfo(title: HostsSidebarStrings.hosts, symbol: "server.rack", badge: machines.isEmpty ? nil : machines.count)
        header.activity = machines.contains(where: { $0.isConnecting && !$0.failed }) ? .working : .idle
        add(Self.headerID, header)
        guard expanded else { return items }

        var addHost = SidebarItemInfo(title: HostsSidebarStrings.addHost, symbol: "plus")
        addHost.caption = HostsSidebarStrings.addHost
        addHost.indent = 1
        add(Self.addID, addHost)
        for machine in machines {
            var info = SidebarItemInfo(title: machine.name, symbol: symbol(for: machine))
            info.caption = caption(for: machine)
            info.tooltip = machine.failure
            info.indent = 1
            info.isMissing = !machine.isConnected && !machine.isConnecting && machine.serverState == nil
            info.activity = machine.isConnecting && !machine.failed ? .working : .idle
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
        if machine.failed { return MachineRowStrings.failed }
        if let state = machine.serverState {
            switch state {
            case .paused: return MachineRowStrings.paused
            case .resuming: return MachineRowStrings.resuming
            case .failed: return MachineRowStrings.failed
            case .deleted: return MachineRowStrings.deleted
            }
        }
        if machine.isConnecting { return MachineRowStrings.connecting }
        return machine.isConnected ? MachineRowStrings.connected : MachineRowStrings.offline
    }
}
