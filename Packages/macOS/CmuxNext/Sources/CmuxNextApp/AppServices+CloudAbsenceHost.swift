import CmuxNextCloudUI

// Kept Cloud workspaces (P-AUSTIN B7): one-line forwards to the App's owners.
extension AppServices: CloudWorkspaceAbsenceHost {
    func cloudAbsenceIsListed(workspace id: String) -> Bool { machines.workspace(id: id) != nil }
    func cloudAbsenceSavedMachine(workspace id: String) -> String? { windows.seenMachine[id] }
    func cloudAbsenceIsCloudMachine(_ machineID: String) -> Bool { MachineRegistry.isCloudMachineID(machineID) }
    func cloudAbsenceIsGone(workspace id: String) -> Bool { windows.isDead(id) }
    func cloudAbsenceAccount() -> (cloudOn: Bool, signedIn: Bool, restoring: Bool) { (!machines.isFeatureDisabled(.cloud), windows.cloudList(cloud).isSignedIn, windows.cloudList(cloud).isRestoring) }
    func cloudAbsenceMachine(_ machineID: String) -> (listed: Bool, live: Bool) { (machines.session(machineID) != nil, machines.session(machineID)?.machine.status.isLive == true) }
}
