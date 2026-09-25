import Foundation

/// A remote cmux-tui workspace binding. The legacy storage field names remain
/// compatible with saved Cloud sessions; SSH uses its reserved `ssh:` machine key.
struct WorkspaceCloudVMBinding: Equatable, Sendable {
    let vmID: String
    /// Base is the single persistent cloud workspace the sidebar cloud button reuses.
    let isBase: Bool
    /// The cmux-tui workspace on the machine this local workspace stands for (`ws_…`),
    /// recorded when a remote workspace is opened locally. Local workspace renames
    /// write through to it (`CloudWorkspaceRenameService`).
    let remoteWorkspaceID: String?

    init(vmID: String, isBase: Bool, remoteWorkspaceID: String? = nil) {
        self.vmID = vmID
        self.isBase = isBase
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    /// Machine ids are provider handles (`vivid-newt`, `sc-…`): letters, digits, `.`, `_`, `-`.
    static func normalizedVMID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.range(of: "^(ssh:[a-f0-9]{64}|[A-Za-z0-9._-]{1,128})$", options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }
}
