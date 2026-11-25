// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxNextWakeups
import Darwin
import Foundation
import Security

/// Which code the helper socket admits as an acpmux bridge, and every line
/// of the app that decides it: this app's team, an executable's signing
/// identifier and its cdhash, the requirement (release) or cdhash (ad-hoc
/// development) that ``acpmuxAdmission(executable:teamIdentifier:identifier:hash:)``
/// returns, the `configure` line that gives them to the helper, and the
/// acpmux daemon whose descendants it admits (``daemonStamp(socketPath:executable:)``,
/// sent as `register_acpmux`). The helper checks every bridge's live audit
/// token against them (`AdmissionPolicy` in CmuxCuaHelperCore). Kept out of
/// the launcher so that the risk tier grades this trust decision on its own.
extension ComputerUseHelperV2 {
    /// This app's signing team. Ad-hoc development builds have no team and
    /// retain the same-executable-path peer rule.
    nonisolated static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }()

    /// The code-signing identifier read from an executable. A raced path can
    /// at worst produce a requirement the real helper does not satisfy: the
    /// live audit-token check still requires this app's team.
    nonisolated static func codeIdentifier(_ executable: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }

    /// Release helpers check every bridge's live audit token against its exact
    /// identifier and this app's team. Only ad-hoc development uses a
    /// mutable-path cdhash.
    nonisolated static func acpmuxAdmission(executable: URL, teamIdentifier: String? = ownTeam,
                                            identifier: (URL) -> String? = codeIdentifier,
                                            hash: (URL) -> Data? = cdhash)
        -> (hashes: [String], requirement: String?) {
        if let teamIdentifier {
            let plain = { (text: String) in
                !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            }
            guard plain(teamIdentifier), let identifier = identifier(executable), plain(identifier) else { return ([], nil) }
            return ([], "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\"")
        }
        return (hash(executable).map { [hex($0)] } ?? [], nil)
    }

    /// The cdhash of a signed executable on disk.
    nonisolated static func cdhash(_ url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }

    /// pid + start time of the process listening on `socketPath`, when the
    /// connected peer runs as this user and runs `executable`. No team gate on
    /// a same-user acpmux socket ("acpmux is too belt and suspenders there", Leo).
    @concurrent nonisolated static func daemonStamp(socketPath: String, executable: URL) async
        -> (pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64)? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: socketPath.utf8)
            buffer[socketPath.utf8.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // This probe only connects and reads the peer; it never writes. Still no SIGPIPE.
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // concurrency-allow: @concurrent, never on the main actor; a local Unix socket connect.
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        guard let peer = UnixSocketPeer(descriptor: descriptor), peer.uid == getuid(), peer.runs(executable) else {
            return nil
        }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(peer.pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { return nil }
        return (peer.pid, info.pbi_start_tvsec, info.pbi_start_tvusec)
    }

    /// The `configure` line on the helper's stdin: its sockets, both secrets,
    /// and the acpmux bridge admission `admit` gives for `acpmuxExecutable`
    /// (none: no bridge is admitted by code identity).
    nonisolated static func configureLine(socket: String, hostSocket: String, hostSecret: Data, secret: Data,
                                          acpmuxExecutable: URL?,
                                          admit: (URL) -> (hashes: [String], requirement: String?) = {
                                              ComputerUseHelperV2.acpmuxAdmission(executable: $0)
                                          }) -> Data {
        let admission: (hashes: [String], requirement: String?) = acpmuxExecutable.map(admit)
            ?? (hashes: [], requirement: nil)
        return line(["type": "configure", "socket": socket, "host_socket": hostSocket,
                     "host_secret": hex(hostSecret), "secret": hex(secret),
                     "acpmux_cdhashes": admission.hashes,
                     "acpmux_requirement": admission.requirement.map { $0 as Any } ?? NSNull()])
    }

    /// The `register_acpmux` line for an acpmux daemon ``daemonStamp(socketPath:executable:)`` named:
    /// its descendants (agent MCP bridges) may then use the helper.
    nonisolated static func registerLine(_ stamp: (pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64)) -> Data {
        line(["type": "register_acpmux", "pid": Int(stamp.pid),
              "start_sec": Int(stamp.startSeconds), "start_usec": Int(stamp.startMicroseconds)])
    }

    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
