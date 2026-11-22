import CmuxNextDaemon

/// The daemon command scope `action.run` binds around a handler
/// (`DaemonCommandScope`), named here so files that speak the control
/// socket's JSON need not import the daemon module and its wire JSON type.
typealias ControlCommandScope = DaemonCommandScope

/// An object a daemon command created (`DaemonCreatedObject`).
typealias ControlCreatedObject = DaemonCreatedObject
