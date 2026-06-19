/// Selection side effect requested by `sidebar.custom.select`.
public struct ControlCustomSidebarSelection: Sendable, Equatable {
    /// Provider id to persist as the active sidebar provider.
    public let providerID: String

    /// Custom sidebar name selected by the command.
    public let name: String

    /// Creates a custom-sidebar selection request.
    ///
    /// - Parameters:
    ///   - providerID: Provider id to persist as the active sidebar provider.
    ///   - name: Custom sidebar name selected by the command.
    public init(providerID: String, name: String) {
        self.providerID = providerID
        self.name = name
    }
}
