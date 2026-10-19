import CmuxNextWakeups
import Darwin
import Foundation
import Security

/// The bundle fixes the executable and code hash before launch. A pid or path alone never authorizes it.
struct NativeCloudExecutable: Sendable {
    let binary: URL
    private let requirement: String

    init(bundle: Bundle) throws {
        guard let resources = bundle.resourceURL else { throw POSIXError(.EACCES) }
        let root = resources.resolvingSymlinksInPath()
        binary = root.appendingPathComponent("bin/cmux-tui").resolvingSymlinksInPath()
        guard binary.path == root.appendingPathComponent("bin/cmux-tui").path else { throw POSIXError(.EACCES) }
        _ = try Self.signing(bundle.bundleURL)
        let information = try Self.signing(binary)
        guard let hash = information[kSecCodeInfoUnique as String] as? Data, (20...32).contains(hash.count) else { throw POSIXError(.EACCES) }
        requirement = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
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
