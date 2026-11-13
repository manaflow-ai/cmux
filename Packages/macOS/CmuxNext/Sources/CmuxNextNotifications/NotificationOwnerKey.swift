/// The resource a notification highlight record belongs to: a workspace or a tab on one machine's daemon session.
///
/// A dismissal on one machine, or on an earlier session of the same daemon (which numbers its resources anew), never
/// reaches a record with the same id elsewhere: forked machines keep their tab ids.
package struct NotificationOwnerKey: Hashable, Sendable {
    /// The machine that holds the resource (`MachineRegistry.localID` for this Mac).
    package let machine: String
    /// The daemon session the id belongs to; nil before the daemon's handshake.
    package let session: String?
    /// The workspace or tab id on that session.
    package let id: String

    /// - Parameters:
    ///   - machine: the machine that holds the resource.
    ///   - session: its daemon session, nil when not known yet.
    ///   - id: the workspace or tab id.
    package init(machine: String, session: String?, id: String) {
        self.machine = machine
        self.session = session
        self.id = id
    }
}
