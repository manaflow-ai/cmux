import Foundation

/// The sidebar Hosts section's titles (HostsSidebar.xcstrings). Its state words are the Machines page's
/// (`MachineRowStrings`).
nonisolated enum HostsSidebarStrings {
    static var hosts: String { text("hostsSidebar.header", "Hosts") }
    static var addHost: String { text("hostsSidebar.addHost", "Add Host…") }

    private static func text(_ key: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: key, value: english, table: "HostsSidebar")
    }
}
