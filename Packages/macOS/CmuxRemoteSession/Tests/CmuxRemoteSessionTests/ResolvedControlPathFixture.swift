import CmuxFoundation

enum ResolvedControlPathFixture {
    /// A resolved socket in the private directory cmux uses on this machine.
    static let path =
        (SSHConnectionSharingOptions().controlSocketDirectoryPath ?? "/unavailable-cmux-ssh") +
        "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
