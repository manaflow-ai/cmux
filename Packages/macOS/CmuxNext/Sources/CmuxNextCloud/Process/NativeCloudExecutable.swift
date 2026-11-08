import CmuxNextWakeups
import Darwin
import Foundation
import Security

/// Which check refused the Native link's executable or child. Each case names one check and carries no path,
/// hash or key, so `link_route` says why Native fell back.
package enum NativeCloudExecutableRefusal: Error, Equatable, CustomStringConvertible {
    case ownSigning(Int32)
    case noResources
    case binaryMoved
    case signing(String, Int32)
    case noCodeHash
    case publisher(expected: String, app: String?, binary: String?)
    case peer
    case startupSize
    case bundle
    case processStart

    package var description: String {
        switch self {
        case .ownSigning(let status): "native executable refused: the app's own signature is unreadable (OSStatus \(status))"
        case .noResources: "native executable refused: the bundle has no Resources"
        case .binaryMoved: "native executable refused: bin/cmux resolves outside the bundle"
        case .signing(let what, let status): "native executable refused: \(what) signature check failed (OSStatus \(status))"
        case .noCodeHash: "native executable refused: cmux-tui has no code hash"
        case .publisher(let expected, let app, let binary):
            "native executable refused: team \(expected) expected, app \(app ?? "none"), cmux-tui \(binary ?? "none")"
        case .peer: "native executable refused: the broker peer is not the started cmux-tui"
        case .startupSize: "native executable refused: the link startup is empty or too large"
        case .bundle: "native executable refused: the app bundle could not be opened"
        case .processStart: "native executable refused: the started cmux-tui could not be identified"
        }
    }
}

/// The bundle fixes the executable and code hash before launch. A pid or path alone never authorizes it.
package struct NativeCloudExecutable: Sendable {
    package enum Publisher: Sendable {
        case team(String)
        /// An app signed with no team id (ad hoc): debug and test builds and the fleet's DEV builds. There is no
        /// publisher to pin, so the child is pinned by its code hash alone. Whoever can swap the bundled binary of
        /// such an app can already change the app itself, so a team-signed app never takes this path.
        case development

        package static func current() throws -> Self {
            if let team = try NativeCloudExecutable.ownTeam() { return .team(team) }
            return .development
        }
    }
    let binary: URL
    private let requirement: String

    init(bundle: Bundle, publisher: Publisher) throws {
        guard let resources = bundle.resourceURL else { throw NativeCloudExecutableRefusal.noResources }
        let root = resources.resolvingSymlinksInPath()
        // bin/cmux is the cmux-tui binary itself; bin/cmux-tui is a relative symlink to it in every bundle
        // (scripts/install-cmux-tui-client.sh), and only argv[0] "acpmux" picks another program. So the child is
        // pinned to the real file, and any symlink there is refused.
        binary = root.appendingPathComponent("bin/cmux").resolvingSymlinksInPath()
        guard binary.path == root.appendingPathComponent("bin/cmux").path else { throw NativeCloudExecutableRefusal.binaryMoved }
        let bundleInformation = try Self.signing(bundle.bundleURL, what: "app")
        let information = try Self.signing(binary, what: "cmux-tui")
        guard let hash = information[kSecCodeInfoUnique as String] as? Data, (20...32).contains(hash.count) else { throw NativeCloudExecutableRefusal.noCodeHash }
        var text = "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
        switch publisher {
        case .team(let team):
            guard team.utf8.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
                  bundleInformation[kSecCodeInfoTeamIdentifier as String] as? String == team,
                  information[kSecCodeInfoTeamIdentifier as String] as? String == team else {
                throw NativeCloudExecutableRefusal.publisher(expected: team,
                                                            app: bundleInformation[kSecCodeInfoTeamIdentifier as String] as? String,
                                                            binary: information[kSecCodeInfoTeamIdentifier as String] as? String)
            }
            text += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        case .development:
            // The app has no team id (Publisher.current), so neither may the child claim one: the code hash pins it.
            guard bundleInformation[kSecCodeInfoTeamIdentifier as String] == nil else {
                throw NativeCloudExecutableRefusal.publisher(expected: "none", app: bundleInformation[kSecCodeInfoTeamIdentifier as String] as? String,
                                                            binary: information[kSecCodeInfoTeamIdentifier as String] as? String)
            }
        }
        requirement = text
    }

    func verify(descriptor: Int32, child: ChildProcess, started: NativeCloudProcessStart) throws {
        guard child.isRunning, child.pid == started.pid, NativeCloudProcessStart(pid: started.pid) == started,
              let peer = UnixSocketPeer(descriptor: descriptor), peer.pid == started.pid, peer.uid == geteuid(),
              peer.runs(binary), peer.satisfies(requirement), child.isRunning,
              NativeCloudProcessStart(pid: started.pid) == started else { throw NativeCloudExecutableRefusal.peer }
    }

    private static func signing(_ url: URL, what: String) throws -> [String: Any] {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw NativeCloudExecutableRefusal.signing(what, created) }
        // concurrency-allow: only NativeCloudLinkChild.launch builds this, inside its BackgroundWork lane (mayBlock: .system), off the main thread and the actor's executor.
        let valid = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        guard valid == errSecSuccess else { throw NativeCloudExecutableRefusal.signing(what, valid) }
        var value: CFDictionary?
        let read = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value)
        guard read == errSecSuccess, let information = value as? [String: Any] else { throw NativeCloudExecutableRefusal.signing(what, read) }
        return information
    }

    private static func ownTeam() throws -> String? {
        var own: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &code) == errSecSuccess, let code else { throw NativeCloudExecutableRefusal.ownSigning(errSecCSStaticCodeNotFound) }
        var value: CFDictionary?
        let read = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &value)
        guard read == errSecSuccess, let information = value as? [String: Any] else { throw NativeCloudExecutableRefusal.ownSigning(read) }
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
