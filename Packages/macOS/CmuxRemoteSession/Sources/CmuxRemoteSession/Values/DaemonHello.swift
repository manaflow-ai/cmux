/// The parsed `hello` response from a cmuxd-remote daemon: identity, version,
/// advertised capabilities, and the remote path it answers from. Lifted
/// one-for-one from the legacy controller's nested type.
struct DaemonHello {
    let name: String
    let version: String
    let capabilities: [String]
    let remotePath: String
}
