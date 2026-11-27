import CmuxCloudMachines

/// Selects the existing preference owner for a native outline insertion.
public enum CloudSidebarDropOperation: Sendable {
    case organization(CloudSidebarOrganizationAction)
    case machine(String, CloudMachineMove)
    /// Move one remote browser tab into a sibling workspace on its machine.
    case browser(String, String, String)
}
