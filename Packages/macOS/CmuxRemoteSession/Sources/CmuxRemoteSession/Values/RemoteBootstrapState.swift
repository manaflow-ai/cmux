/// Snapshot of the remote host state gathered by the single bootstrap probe:
/// platform, `$HOME`, and whether the versioned daemon binary is already
/// installed. Lifted one-for-one from the legacy controller's nested type.
struct RemoteBootstrapState {
    let platform: RemotePlatform
    let homeDirectory: String
    let binaryExists: Bool
}
