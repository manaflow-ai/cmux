import CmuxNextCompat
public import Foundation

/// Which Cloud machines a holder home delivered Codex access to, kept beside the holder so the next
/// run of cmux knows them: it picks renewal back up on each (cmux#33878), and a sign-out, an account
/// or team switch or the Cloud off switch erases them, including what an earlier run left (cmux#33877).
/// It holds machine IDs and one flag each, never a token. `erase` marks a machine whose access was
/// asked to be erased but could not be yet (a paused machine): the next run erases it instead of
/// renewing it.
nonisolated public struct CloudCodexDeliveryRecord: Sendable {
    public let file: URL
    private let holderFile: URL

    public init(home: URL) {
        file = home.appendingPathComponent("delivered-machines.json", isDirectory: false)
        holderFile = home.appendingPathComponent("holder-id", isDirectory: false)
    }

    /// This holder's opaque ID, made on first use. Each delivered access file carries it, so a run takes
    /// back only what this holder delivered, never another Mac's or account's delivery to the machine.
    public func holderID() -> String {
        if let data = try? Data(blockingContentsOf: holderFile),
           let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString.lowercased()
        write(Data((id + "\n").utf8), to: holderFile)
        return id
    }

    /// Machine ID to whether it waits to be erased.
    public func entries() -> [String: Bool] {
        guard let data = try? Data(blockingContentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? Int == 1,
              let machines = object["machines"] as? [String: Any] else { return [:] }
        var entries: [String: Bool] = [:]
        for (id, value) in machines where !id.isEmpty {
            entries[id] = (value as? [String: Any])?["erase"] as? Bool ?? false
        }
        return entries
    }

    /// A delivery to `machineID`: it renews from now on, even if an earlier ask to erase it failed.
    public func delivered(_ machineID: String) { update { $0[machineID] = false } }

    /// `machineID` holds no access of this holder any more.
    public func forget(_ machineID: String) { update { $0.removeValue(forKey: machineID) } }

    /// A sign-out, a switch or the off switch: whatever is still recorded is erased, not renewed.
    public func markAllForErasure() { update { entries in for id in entries.keys { entries[id] = true } } }

    private func update(_ change: (inout [String: Bool]) -> Void) {
        var entries = entries()
        let before = entries
        change(&entries)
        guard entries != before else { return }
        if entries.isEmpty { try? FileManager.checked.removeItem(at: file); return }
        let object: [String: Any] = ["schema": 1, "machines": entries.mapValues { ["erase": $0] }]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        write(data, to: file)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.blockingWrite(to: url, options: [.atomic])
            try FileManager.checked.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {}
    }
}
