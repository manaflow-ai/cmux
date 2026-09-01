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
        connection: IrxConnection,
        stillAuthorized: @escaping @Sendable (_ remoteEndpointIDHex: String) -> Bool = { _ in true }
    ) async -> Bool {
        // Admission and registration are separate async phases. Re-check the
        // atomically readable list immediately before publishing the session
        // so a directory revocation that lands between them cannot leave a
        // newly admitted connection outside the enforcement sweep.
        guard stillAuthorized(connection.remoteEndpointIDHex) else {
            journal.record(
                "registry", "admit-revoked",
                ["device": deviceID, "session": sessionID]
            )
            await connection.close(code: .revoked, origin: .local)
            return false
        }
        let previous = sessionsByDevice.updateValue(
            (sessionID, connection), forKey: deviceID)
        if let previous {
            journal.record(
                "registry", "superseded",
                ["device": deviceID, "old_session": previous.session, "new_session": sessionID]
            )
            await previous.connection.close(code: .superseded, origin: .local)
        }
        return true
    }

    /// Removes a session when its supervisor exits, unless a newer session
    /// already replaced it.
    public func remove(deviceID: String, sessionID: String) {
        guard sessionsByDevice[deviceID]?.session == sessionID else { return }
        sessionsByDevice[deviceID] = nil
    }

    public func closeAll(code: IrxCloseCode) async {
        let entries = Array(sessionsByDevice)
        for (deviceID, entry) in entries {
            await entry.connection.close(code: code, origin: .local)
            if sessionsByDevice[deviceID]?.session == entry.session {
                sessionsByDevice[deviceID] = nil
            }
        }
    }

    /// Closes every live session whose TLS-authenticated peer endpoint the
    /// predicate selects (directory enforcement: a device revoked or dropped
    /// from the list is cut NOW, not at its next admission).
    public func closeAll(
        code: IrxCloseCode,
        matching shouldClose: @Sendable (_ remoteEndpointIDHex: String) -> Bool
    ) async {
        // Snapshot before awaiting connection shutdown. Actor reentrancy can
        // admit or replace sessions while a close is in flight, and mutating
        // the live dictionary during iteration would otherwise invalidate the
        // collection and skip entries.
        let entries = Array(sessionsByDevice)
        for (deviceID, entry) in entries
        where shouldClose(entry.connection.remoteEndpointIDHex) {
            journal.record(
                "registry", "list-enforced-close",
                [
                    "device": deviceID,
                    "session": entry.session,
                    "code": code.rawValue,
                ]
            )
            await entry.connection.close(code: code, origin: .local)
            if sessionsByDevice[deviceID]?.session == entry.session {
                sessionsByDevice[deviceID] = nil
            }
        }
    }
}
