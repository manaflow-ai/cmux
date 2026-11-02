import CmuxNextWakeups
import Darwin
import Foundation
import os
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
            throw NativeCloudExecutable.refused("this app has no signing team (a release takes only a team-signed app)")
            #endif
        }
    }
    let binary: URL
    private let requirement: String

    init(bundle: Bundle, publisher: Publisher) throws {
        guard let resources = bundle.resourceURL else { throw Self.refused("the bundle has no Resources") }
        let root = resources.resolvingSymlinksInPath()
        binary = root.appendingPathComponent("bin/cmux-tui").resolvingSymlinksInPath()
        guard binary.path == root.appendingPathComponent("bin/cmux-tui").path else {
            throw Self.refused("bin/cmux-tui resolves outside the bundle: \(binary.path)")
        }
        let bundleInformation = try Self.signing(bundle.bundleURL)
        let information = try Self.signing(binary)
        guard let hash = information[kSecCodeInfoUnique as String] as? Data, (20...32).contains(hash.count) else {
            throw Self.refused("cmux-tui has no code hash")
        }
        var text = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        switch publisher {
        case .team(let team):
            guard team.utf8.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
                  bundleInformation[kSecCodeInfoTeamIdentifier as String] as? String == team,
                  information[kSecCodeInfoTeamIdentifier as String] as? String == team else {
                throw Self.refused("the bundle or cmux-tui is not signed by the app's team")
            }
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
        guard child.isRunning, child.pid == started.pid, NativeCloudProcessStart(pid: started.pid) == started else {
            throw Self.refused("the link child exited or was replaced")
        }
        guard let peer = UnixSocketPeer(descriptor: descriptor), peer.pid == started.pid, peer.uid == geteuid() else {
            throw Self.refused("the broker peer is not the link child")
        }
        guard peer.runs(binary) else {
            throw Self.refused("the broker peer runs \(peer.executablePath), not \(binary.resolvingSymlinksInPath().path)")
        }
        guard peer.satisfies(requirement) else { throw Self.refused("the broker peer fails the code requirement \(requirement)") }
        guard child.isRunning, NativeCloudProcessStart(pid: started.pid) == started else {
            throw Self.refused("the link child exited or was replaced")
        }
    }

    /// EACCES, after logging which check refused (the error alone names none of them).
    static func refused(_ reason: String) -> POSIXError {
        Logger(subsystem: "com.cmuxterm.app.next", category: "cloud.native")
            .error("native link refused: \(reason, privacy: .public)")
        return POSIXError(.EACCES)
    }

    private static func signing(_ url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw refused("no static code for \(url.lastPathComponent): \(created)") }
        // concurrency-allow: only NativeCloudLinkChild.launch builds this, inside its BackgroundWork lane (mayBlock: .system), off the main thread and the actor's executor.
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard validity == errSecSuccess else { throw refused("\(url.lastPathComponent)'s signature is invalid: \(validity)") }
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
              let information = value as? [String: Any] else { throw refused("no signing information for \(url.lastPathComponent)") }
        return information
    }

    private static func ownTeam() throws -> String? {
        var own: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code else { throw refused("the app's own code is unreadable") }
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
              let information = value as? [String: Any] else { throw refused("no signing information for the app") }
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
