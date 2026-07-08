/// Capabilities cmux requires from a cmuxd-remote daemon, as advertised in the
/// daemon's `hello` response.
///
/// Raw values are the wire capability strings; do not rename them.
public enum RemoteDaemonCapability: String, Sendable, CaseIterable {
    /// Push-based proxy streaming (`proxy.stream.push`).
    case proxyStreamPush = "proxy.stream.push"
    /// Persistent PTY sessions (`pty.session`).
    case ptySession = "pty.session"
    /// Tokenized PTY attachments (`pty.session.token`).
    case ptySessionToken = "pty.session.token"
    /// Persistent-daemon PTY sessions that survive SSH disconnects
    /// (`pty.session.persistent_daemon`).
    case ptyPersistentDaemon = "pty.session.persistent_daemon"
    /// Write acknowledgement notifications (`pty.write.notification`).
    case ptyWriteNotification = "pty.write.notification"
    /// Resize notifications (`pty.resize.notification`).
    case ptyResizeNotification = "pty.resize.notification"

    /// The capability family backing persistent SSH PTY sessions; missing any
    /// of these yields the persistent-PTY reconnect message.
    public static let persistentPTYFamily: Set<String> = [
        RemoteDaemonCapability.ptySession.rawValue,
        RemoteDaemonCapability.ptySessionToken.rawValue,
        RemoteDaemonCapability.ptyPersistentDaemon.rawValue,
        RemoteDaemonCapability.ptyWriteNotification.rawValue,
        RemoteDaemonCapability.ptyResizeNotification.rawValue,
    ]
}
