// The daemon service layer lives in its own target (CmuxNextDaemonService: DaemonService,
// FrameBatcher, RefusalStrings, CloudStrings, quit choices). This one re-export makes it
// visible to every App file and to `@testable import CmuxNextApp` tests, as before the move.
@_exported import CmuxNextDaemonService
