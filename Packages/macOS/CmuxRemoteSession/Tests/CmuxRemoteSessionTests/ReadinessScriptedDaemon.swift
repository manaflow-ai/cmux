/// What the scripted remote host reports about its cmuxd-remote install.
enum ReadinessScriptedDaemon: Sendable {
    /// No daemon is installed, and the app under test carries no manifest to
    /// install one from, so bootstrap can never succeed.
    case missing
    /// A daemon is installed and answers `hello` with these capabilities.
    case installed(capabilities: [String])
}
