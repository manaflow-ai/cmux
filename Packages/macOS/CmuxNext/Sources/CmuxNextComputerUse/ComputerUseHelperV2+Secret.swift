// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security

/// The helper socket's per-launch secret and where acpmux reads it: the
/// second admission check after the bridge's code identity
/// (``acpmuxAdmission(executable:teamIdentifier:identifier:hash:)``). The
/// secret goes to the helper in the `configure` line and to acpmux in
/// `endpoint.json` (0600, in this user's private directory). Kept out of
/// the launcher so that the risk tier grades it on its own.
extension ComputerUseHelperV2 {
    nonisolated static func makeSecret() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// endpoint.json for acpmux: 0600, written to a temporary name and renamed.
    /// `owner` is the helper's pid, with its start time, so an acpmux daemon
    /// that outlives a crash of this app sees the file is stale (cx-zgk0).
    @concurrent nonisolated static func writeEndpoint(path: String, socket: String, secret: Data, owner: pid_t) async -> Bool {
        var fields: [String: Any] = ["protocol": 1, "socket": socket, "secret": hex(secret), "pid": Int(owner)]
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(owner, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize {
            fields["start_sec"] = Int(info.pbi_start_tvsec)
            fields["start_usec"] = Int(info.pbi_start_tvusec)
        }
        let body = line(fields)
        let temporary = path + ".tmp"
        unlink(temporary)
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        // concurrency-allow: @concurrent, never on the main actor; one small local file.
        let written = body.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == body.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            return false
        }
        return true
    }
}
