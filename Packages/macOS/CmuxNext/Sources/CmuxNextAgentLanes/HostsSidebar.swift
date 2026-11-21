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

    /// How the section lays out its rows. The gallery (`HostsSidebarGalleryTests`) draws all three;
    /// the app draws ``Layout/addLast``.
    public enum Layout: String, CaseIterable, Sendable {
        /// Hosts header, Add Host, then the machines (#46736's first cut).
        case addFirst
        /// Hosts header, the machines, then Add Host closing the list, as the Machines page ends
        /// with Add Machine… (design/machines-section.md). Shipped.
        case addLast
        /// No header: the machines at the top level, then Add Host. Nothing folds or counts them.
        case flat
    }

    @MainActor
    static func rows(machines: [MachineSectionRow], expanded: Bool, layout: Layout = .addLast) -> [SidebarTransientItem] {
        var items: [SidebarTransientItem] = []
        var previous: [LayoutItemRef] = [.app("cmux/app-store"), SidebarTransientItem.channels.item.ref,
                                          SidebarLayoutDocument.homeRef, .builtIn(.home)]
        func add(_ id: LayoutItemID, _ info: SidebarItemInfo) {
            items.append(SidebarTransientItem(id: id, info: info, after: previous))
            previous = [LayoutItemRef(kind: "client", value: id.rawValue)]
        }

        let indent = layout == .flat ? 0 : 1
        if layout != .flat {
            var header = SidebarItemInfo(title: HostsSidebarStrings.title, symbol: "server.rack", badge: machines.isEmpty ? nil : machines.count)
            header.activity = machines.contains(where: { $0.isConnecting && !$0.failed }) ? .working : .idle
            add(Self.headerID, header)
            guard expanded else { return items }
        }

        var addHost = SidebarItemInfo(title: HostsSidebarStrings.addHost, symbol: "plus")
        addHost.indent = indent
        if layout == .addFirst { add(Self.addID, addHost) }
        for machine in machines {
            var info = SidebarItemInfo(title: machine.name, symbol: symbol(for: machine))
            // A row draws no state word (design/sidebar.md: state is the spinner or the dimmed name);
            // a tile draws its caption, and the tooltip says it with the failure when there is one.
            let state = caption(for: machine)
            info.caption = state
            info.tooltip = [machine.name, state, machine.failure].compactMap { $0 }.joined(separator: "\n")
            info.accessibilityTitle = state.map { HostsSidebarStrings.label(machine.name, $0) } ?? machine.name
            info.indent = indent
            info.isMissing = !machine.isConnected && !machine.isConnecting
            info.activity = machine.isConnecting && !machine.failed ? .working : .idle
            add(LayoutItemID(Self.rowPrefix + machine.id), info)
        }
        if layout != .addFirst { add(Self.addID, addHost) }
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

    /// The state word, only when there is something to read: nil for a connected machine.
    private static func caption(for machine: MachineSectionRow) -> String? {
        if machine.failed { return HostsSidebarStrings.failed }
        if let state = machine.serverState {
            return switch state {
            case .paused: HostsSidebarStrings.paused
            case .resuming: HostsSidebarStrings.resuming
            case .failed: HostsSidebarStrings.failed
            case .deleted: HostsSidebarStrings.deleted
            }
        }
        if machine.isConnecting { return HostsSidebarStrings.connecting }
        return machine.isConnected ? nil : HostsSidebarStrings.offline
    }
}

/// The Hosts section's words, in every app language (`Localizable.xcstrings`).
enum HostsSidebarStrings {
    static var title: String { String(localized: "sidebar.hosts.title", defaultValue: "Hosts", bundle: .module) }
    static var addHost: String { String(localized: "sidebar.hosts.add", defaultValue: "Add Host…", bundle: .module) }
    static var connecting: String { String(localized: "sidebar.hosts.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var offline: String { String(localized: "sidebar.hosts.offline", defaultValue: "Offline", bundle: .module) }
    static var failed: String { String(localized: "sidebar.hosts.failed", defaultValue: "Failed", bundle: .module) }
    static var paused: String { String(localized: "sidebar.hosts.paused", defaultValue: "Paused", bundle: .module) }
    static var resuming: String { String(localized: "sidebar.hosts.resuming", defaultValue: "Resuming…", bundle: .module) }
    static var deleted: String { String(localized: "sidebar.hosts.deleted", defaultValue: "Deleted", bundle: .module) }
    /// VoiceOver: "studio-mini, Offline".
    static func label(_ name: String, _ state: String) -> String {
        String(format: String(localized: "sidebar.hosts.label", defaultValue: "%1$@, %2$@", bundle: .module), name, state)
    }
}
