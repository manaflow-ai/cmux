/// A kept tab to restart a shell in (`end-terminals-keep-layout-v1`, wire
/// `relaunch`): the workspace store's keep-layout record, with the
/// directory the tab's shell was in when Quit's End Sessions, Keep Layout
/// ended it.
public struct TabRelaunch: Sendable, Hashable, Codable {
    public var cwd: String?

    public init(cwd: String?) {
        self.cwd = cwd
    }
}
