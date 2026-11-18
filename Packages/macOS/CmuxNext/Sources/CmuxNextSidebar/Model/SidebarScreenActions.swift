public import Foundation

/// Adds screen action metadata to existing machine sections without changing their layout.
/// Inputs are value projections from the device hub and authenticated daemon identities; the sidebar
/// has no dependency on either service and never treats a display name as a device identity.
public nonisolated struct SidebarScreenActions {
    private let macs: [String: Bool]
    private let aliases: [String: String]
    private let sharing: Bool

    /// - Parameters:
    ///   - macs: Verified device IDs (lowercase) of screens this Mac views (Macs and Linux desktops,
    ///     `HubDevice.macScreenAvailability`), mapped to their online state.
    ///   - aliases: Actual daemon route IDs mapped to their authenticated screen worker UUIDs.
    ///   - sharing: This Mac shares its screen now (this device's `HubDevice.macScreenShared`).
    public init(macs: [String: Bool], aliases: [String: String], sharing: Bool = false) {
        self.macs = macs
        self.aliases = aliases
        self.sharing = sharing
    }

    /// Decorates SSH and server sections. Unresolved devices and ones this Mac cannot view have no View action;
    /// an offline host keeps its action disabled. Cloud and local actions need no hub identity; the local
    /// machine carries whether it is sharing now.
    public func applying(to sections: [SidebarSection]) -> [SidebarSection] {
        sections.map { section in
            guard var machine = section.machine else { return section }
            switch machine.kind {
            case .local:
                guard machine.screenShared != sharing else { return section }
                machine.screenShared = sharing
            case .ssh, .server:
                let id = aliases[machine.id.rawValue]?.lowercased()
                machine.screenDeviceID = id.flatMap { macs[$0] == nil ? nil : $0 }
                machine.screenAvailable = id.flatMap { macs[$0] } == true
            case .cloud:
                return section
            }
            var result = section
            result.kind = .machine(machine)
            return result
        }
    }
}
