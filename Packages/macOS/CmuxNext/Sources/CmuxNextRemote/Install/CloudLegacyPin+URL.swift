public import CmuxNextCloud

public nonisolated extension CloudLegacyPin {
    /// The immutable per-commit release `cmux link machine update` downloads too.
    var url: String { "\(RemoteInstallPlan.base.absoluteString)/\(commit)/cmux-tui-\(Self.target)" }
}
