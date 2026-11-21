import Foundation

/// Mirrors the app's windows into the daemon's window records
/// (`window-records-v1`, plans/cmux-next/reopen-closed.md 4): which
/// workspaces each lists and whether it is open. Closed history names the
/// window each group left from them, and a window that closes becomes a
/// `window` group. Only those fields go there (a selection change writes
/// nothing); the window projection stays the restore record. A failed write
/// is logged and tried again on the next sync.
public final class WindowRecordMirror {
    /// The records this install last put, by window id: written again only when they change.
    private var written: [String: JSONValue] = [:]
    /// Whether this run read the daemon's records of this install once, so
    /// records of windows that are gone (an earlier run) get deleted.
    private var reconciled = false
    /// The fields each written record was made from: a record whose fields are these again is not encoded. Its
    /// workspace keys are the save's kept list (`WindowRecordMembership`), so the check answers from storage identity
    /// and a switch, which changes no list, encodes no record.
    private var writtenFields: [String: Fields] = [:]
    /// Records this mirror encoded, since it was made (`SwitchSaveCostTests`).
    public private(set) var encoded = 0

    private struct Fields: Equatable {
        var open: Bool
        var keys: [WorkspaceKey]
        var shown: WorkspaceKey?
    }

    public init() {}

    /// Puts `records` (this install's windows) and deletes the records of windows that are gone.
    public func sync(_ records: [WindowRecord], installID: String, client: StateResourceClient,
                     log: (String) -> Void) async {
        if !reconciled, let stored = try? await client.windowRecordIDs(installID: installID) {
            reconciled = true
            // Known as written, so the loop below deletes the ones no window wants.
            for id in stored where written[id] == nil { written[id] = .null }
        }
        var wanted = Set<String>()
        for record in records {
            wanted.insert(record.id)
            let made = Fields(open: !record.isClosed, keys: record.workspaceKeys, shown: record.workspaceKey)
            if written[record.id] != nil, writtenFields[record.id] == made { continue }
            encoded += 1
            var fields: [String: JSONValue] = ["id": .string(record.id), "open": .bool(made.open),
                                               "workspace_keys": .array(made.keys.map { .string($0.rawValue) })]
            if let key = made.shown { fields["workspace_key"] = .string(key.rawValue) }
            let value = JSONValue.object(fields)
            guard written[record.id] != value else { writtenFields[record.id] = made; continue }
            do {
                try await client.putWindowRecord(installID: installID, windowID: record.id, record: value)
                written[record.id] = value
                writtenFields[record.id] = made
            } catch {
                log("window_record.put failed: \(error)")
            }
        }
        for id in Set(written.keys).subtracting(wanted) {
            do {
                try await client.deleteWindowRecord(installID: installID, windowID: id)
                written[id] = nil
                writtenFields[id] = nil
            } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                written[id] = nil
                writtenFields[id] = nil
            } catch {
                // Kept: the next sync tries the delete again.
                log("window_record.delete failed: \(error)")
            }
        }
    }
}
