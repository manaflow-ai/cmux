import Foundation

/// Supersession authority on the host: a new admitted connection from a
/// device immediately replaces that device's old session, so a dead process
/// can never block re-admission (the old stack held a dead QUIC session ~85s
/// and blocked the relaunched app).
public actor IrxServerSessionRegistry {
    private var sessionsByDevice: [String: (session: String, connection: IrxConnection)] = [:]
    private let journal: IrxJournal

    public init(journal: IrxJournal) {
        self.journal = journal
    }

    public var activeSessionCount: Int { sessionsByDevice.count }

    /// Registers a newly admitted connection, closing the device's previous
    /// session with the attributed `superseded` reason.
    public func admit(
        deviceID: String,
        sessionID: String,
        connection: IrxConnection
    ) async {
        if let previous = sessionsByDevice[deviceID] {
            journal.record(
                "registry", "superseded",
                ["device": deviceID, "old_session": previous.session, "new_session": sessionID]
            )
            await previous.connection.close(code: .superseded, origin: .local)
        }
        sessionsByDevice[deviceID] = (sessionID, connection)
    }

    /// Removes a session when its supervisor exits, unless a newer session
    /// already replaced it.
    public func remove(deviceID: String, sessionID: String) {
        guard sessionsByDevice[deviceID]?.session == sessionID else { return }
        sessionsByDevice[deviceID] = nil
    }

    public func closeAll(code: IrxCloseCode) async {
        for entry in sessionsByDevice.values {
            await entry.connection.close(code: code, origin: .local)
        }
        sessionsByDevice.removeAll()
    }
}
