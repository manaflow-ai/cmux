import CmuxFoundation

enum ResolvedControlPathFixture {
    static let path =
        "/tmp/cmux-ssh-\(SSHConnectionSharingOptions().userID)-" +
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
