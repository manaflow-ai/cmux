#if canImport(Security)
import Foundation
import Security

/// This process's code-signing team, read once on the system lane and then held in memory: the acpmux launch
/// check (`AcpmuxEnvironment.resolve`, `AcpmuxServerPeer.executableSignedByAppTeam`) and the Computer Use
/// helper's acpmux admission read ``team`` on whatever thread they run, the main thread included.
///
/// The composition root loads it at launch (`work.post(.userVisible, mayBlock: .system) { install.load() }`);
/// a read before that asks securityd itself through the checked Security seams (``PreloadedValue``). It
/// replaces the static initializers that asked securityd on whichever thread came first (p02-threads-122).
public nonisolated final class SigningTeamInstall: Sendable {
    /// The process's install: the running code's team is the same for every reader.
    public static let process = SigningTeamInstall()

    private let slot: PreloadedValue<String?>

    /// - Parameter read: Reads the team (``readRunningCode()``; tests count reads or give a fixed team).
    public init(read: @escaping @Sendable () -> String? = { SigningTeamInstall.readRunningCode() }) {
        slot = PreloadedValue(read: read)
    }

    /// Whether the team is in memory.
    public var isLoaded: Bool { slot.isLoaded }

    /// This app's team when it is Team-signed; nil for an ad-hoc or unsigned build. In memory after ``load()``.
    public var team: String? { slot.value }

    /// Reads the team so later reads find it in memory. It asks securityd: call it on the system lane.
    public func load() { slot.load() }

    /// Reads the running code's team from its signature through the checked Security seams.
    public static func readRunningCode() -> String? {
        var code: SecCode?
        // SAFETY: SecCodeCopySelf writes one retained SecCode reference into `code`, a local optional.
        guard unsafe blockingSecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        // SAFETY: SecCodeCopyStaticCode writes one retained SecStaticCode reference into `staticCode`, a local optional.
        guard unsafe blockingSecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        // SAFETY: SecCodeCopySigningInformation writes one retained CFDictionary reference into `info`, a local optional.
        guard unsafe blockingSecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess, let info = info as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }
}
#endif
