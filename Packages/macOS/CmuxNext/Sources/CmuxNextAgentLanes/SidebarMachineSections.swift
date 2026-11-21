import Foundation
public import CmuxNextSidebar

/// The per-window machine surface above the durable sidebar document: the Labs Hosts section.
/// Agent chats on other machines stay out of the sidebar (Lawrence 2026-10-26); this binds
/// no `RemoteMachinesSidebar`, so it reads no peers and follows no lanes.
@MainActor
public final class SidebarMachineSections {
    public let hosts: HostsSidebar

    public init(hosts: HostsSidebar = HostsSidebar()) {
        self.hosts = hosts
    }

    public func bind(host: HostsSidebar.Host, visible: @escaping @MainActor () -> Bool) {
        hosts.bind(host: host, visible: visible)
    }

    public func stop() {
        hosts.stop()
    }

    public func topItems() -> [SidebarTransientItem] {
        hosts.isEnabled ? hosts.rows() : []
    }

    public func activate(_ id: LayoutItemID) -> Bool {
        hosts.isEnabled && hosts.activate(id)
    }
}
