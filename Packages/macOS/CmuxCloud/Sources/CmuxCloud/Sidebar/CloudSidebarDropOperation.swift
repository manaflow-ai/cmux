import CmuxCloudMachines

/// Selects the existing preference owner for a native outline insertion.
public enum CloudSidebarDropOperation: Sendable {
    case organization(CloudSidebarOrganizationAction)
    case machine(String, CloudMachineMove)
}
