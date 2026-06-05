enum TerminationSessionPersistenceReason: Sendable {
    case applicationWillTerminate
    case workspaceWillPowerOff
    case sessionDidResignWhileTerminating
    case updateRelaunch
}
