/// Classifies the remote workspace's current sidebar error status entry.
///
/// Pure value/decision helper extracted from the legacy
/// `Workspace.hasProxyOnlyRemoteSidebarError` computed property. The workspace
/// passes the raw value of its `remote.error` status entry (or `nil` when there
/// is none) and this type reports whether that entry is the proxy-only error
/// the connection-state machine raises (status prefix "Remote proxy
/// unavailable"). It deliberately matches only that single phrase, narrower
/// than ``Swift/String/indicatesProxyOnlyRemoteError`` which spans the broader
/// proxy-fault substring set: this asks "is the sidebar currently showing the
/// proxy-only banner", not "could this detail be a proxy fault".
public struct RemoteSidebarErrorClassifier: Sendable {
    /// Creates the classifier.
    public init() {}

    /// Whether `statusEntryValue` is the proxy-only sidebar error, matched
    /// case-insensitively on the `remote proxy unavailable` substring.
    public func isProxyOnly(statusEntryValue: String?) -> Bool {
        guard let statusEntryValue else { return false }
        return statusEntryValue.lowercased().contains("remote proxy unavailable")
    }
}
