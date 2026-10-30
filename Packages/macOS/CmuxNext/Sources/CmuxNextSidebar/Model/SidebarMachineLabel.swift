/// The computer a one-list workspace row names on its second line (`SidebarLayout.machineLabel`): its name and, when
/// it cannot connect, its status, kept apart so a row titled by that name drops the whole name and nothing else
/// (`WorkspaceRowContent.unrepeated`), whatever the name holds.
public nonisolated struct SidebarMachineLabel: Hashable, Sendable, ExpressibleByStringLiteral {
    public var name: String
    public var status: String?

    public init(name: String, status: String? = nil) {
        (self.name, self.status) = (name, status)
    }

    /// A machine with `value` as its name and no status.
    public init(stringLiteral value: String) {
        self.init(name: value)
    }

    /// As the row writes it: `name`, or `name · status`.
    public var text: String {
        status.map { name + WorkspaceRowContent.separator + $0 } ?? name
    }
}
