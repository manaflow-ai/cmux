import CmuxNextWakeups
import Darwin
import Foundation
import Security

/// The bundle fixes the executable and code hash before launch. A pid or path alone never authorizes it.
package struct NativeCloudExecutable: Sendable {
    package enum Publisher: Sendable {
        case team(String)
        #if DEBUG
        case development
        #endif

        package static func current() throws -> Self {
            if let team = try NativeCloudExecutable.ownTeam() { return .team(team) }
            #if DEBUG
            return .development
            #else
            throw POSIXError(.EACCES)
            #endif
        }
    }
    let binary: URL
    private let requirement: String

    init(bundle: Bundle, publisher: Publisher) throws {
        guard let resources = bundle.resourceURL else { throw POSIXError(.EACCES) }
        let root = resources.resolvingSymlinksInPath()
        binary = root.appendingPathComponent("bin/cmux-tui").resolvingSymlinksInPath()
        guard binary.path == root.appendingPathComponent("bin/cmux-tui").path else { throw POSIXError(.EACCES) }
        let bundleInformation = try Self.signing(bundle.bundleURL)
        let information = try Self.signing(binary)
        guard let hash = information[kSecCodeInfoUnique as String] as? Data, (20...32).contains(hash.count) else { throw POSIXError(.EACCES) }
        var text = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        switch publisher {
        case .team(let team):
            guard team.utf8.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
                  bundleInformation[kSecCodeInfoTeamIdentifier as String] as? String == team,
                  information[kSecCodeInfoTeamIdentifier as String] as? String == team else { throw POSIXError(.EACCES) }
            text += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        #if DEBUG
        case .development:
            // Explicit debug/test software identity. This case does not exist in a release.
            break
            #endif
        }
        requirement = text
    }

    func verify(descriptor: Int32, child: ChildProcess, started: NativeCloudProcessStart) throws {
        guard child.isRunning, child.pid == started.pid, NativeCloudProcessStart(pid: started.pid) == started,
              let peer = UnixSocketPeer(descriptor: descriptor), peer.pid == started.pid, peer.uid == geteuid(),
              peer.runs(binary), peer.satisfies(requirement), child.isRunning,
              NativeCloudProcessStart(pid: started.pid) == started else { throw POSIXError(.EACCES) }
    }

    private static func signing(_ url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw POSIXError(.EACCES) }
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
              let information = value as? [String: Any] else { throw POSIXError(.EACCES) }
        return information
    }

    private static func ownTeam() throws -> String? {
        var own: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code else { throw POSIXError(.EACCES) }
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
              let information = value as? [String: Any] else { throw POSIXError(.EACCES) }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

struct NativeCloudProcessStart: Equatable, Sendable {
    let pid: Int32
    private let seconds: UInt64
    private let micros: UInt64
    init?(pid: Int32) {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == geteuid() else { return nil }
        self.pid = pid; seconds = info.pbi_start_tvsec; micros = info.pbi_start_tvusec
    }
}
