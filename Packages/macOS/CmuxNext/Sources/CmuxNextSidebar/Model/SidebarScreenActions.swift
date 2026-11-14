public import Foundation

/// Adds screen action metadata to existing machine sections without changing their layout.
/// Inputs are value projections from the device hub and authenticated daemon identities; the sidebar
/// has no dependency on either service and never treats a display name as a device identity.
public nonisolated struct SidebarScreenActions {
    private let macs: [String: Bool]
    private let aliases: [String: String]

    /// - Parameters:
    ///   - macs: Verified macOS device IDs (lowercase), mapped to their online state.
    ///   - aliases: Actual daemon route IDs mapped to their authenticated screen worker UUIDs.
    public init(macs: [String: Bool], aliases: [String: String]) {
        self.macs = macs
        self.aliases = aliases
    }

    /// Decorates SSH and server sections. Unresolved and non-Mac devices have no View action;
    /// an offline Mac keeps its action disabled. Cloud and local actions need no hub identity.
    public func applying(to sections: [SidebarSection]) -> [SidebarSection] {
        sections.map { section in
            guard var machine = section.machine, machine.kind == .ssh || machine.kind == .server else { return section }
            let id = aliases[machine.id.rawValue]?.lowercased()
            machine.screenDeviceID = id.flatMap { macs[$0] == nil ? nil : $0 }
            machine.screenAvailable = id.flatMap { macs[$0] } == true
            var result = section
            result.kind = .machine(machine)
            return result
        }
    }
}
