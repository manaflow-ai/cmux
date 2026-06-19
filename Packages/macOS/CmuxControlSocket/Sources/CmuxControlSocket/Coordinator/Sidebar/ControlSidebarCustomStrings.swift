/// The localized `sidebar.custom.*` error messages, resolved against the app
/// bundle so ``ControlSidebarCustomWorker`` can shape the localized error
/// envelopes without binding `String(localized:)` to the package bundle (which
/// lacks the keys, silently dropping non-English translations = a wire change).
///
/// Each field carries the exact `String(localized:)` result the legacy
/// `v2CustomSidebar*` bodies produced.
public struct ControlSidebarCustomStrings: Sendable, Equatable {
    /// `socket.sidebar.custom.invalidName` — the empty-name error shared by
    /// `sidebar.custom.validate` and `sidebar.custom.reload`.
    public let invalidName: String

    /// `socket.sidebar.custom.selectMissingName` — the missing-name error for
    /// `sidebar.custom.select`.
    public let selectMissingName: String

    /// Creates the localized custom-sidebar strings.
    ///
    /// - Parameters:
    ///   - invalidName: The empty-name error message.
    ///   - selectMissingName: The select missing-name error message.
    public init(invalidName: String, selectMissingName: String) {
        self.invalidName = invalidName
        self.selectMissingName = selectMissingName
    }
}
