// Who may publish a patch (cmux#13742): outside Debug and bench, a live code build loads a patch
// only when it is signed, validly, by the same team as the running app, so an ad hoc or a
// stranger's dylib in the live folder never runs. The fleet signs patches with the team's ID.
import Foundation
import Security

nonisolated enum PatchSignature {
    /// Throws unless `path` is a validly signed dylib of the running app's team. Off the main
    /// thread: it reads and hashes the file.
    static func check(_ path: String) throws {
        guard let team = runningTeam() else { throw LiveCodeError.notOurTeam("the app itself has no team ID") }
        // A team ID is ten capitals and digits; anything else never goes into the requirement text.
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            throw LiveCodeError.notOurTeam("the app's team ID \(team) is malformed")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            throw LiveCodeError.notOurTeam("unreadable signature")
        }
        // Apple-anchored (a Developer ID or Apple Development certificate) and the same team.
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else {
            throw LiveCodeError.notOurTeam("no requirement for team \(team)")
        }
        // concurrency-allow: called only from LiveEngine, an actor off the main thread
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else { throw LiveCodeError.notOurTeam("team \(team) required (OSStatus \(status))") }
    }

    /// The running app's team ID, from its own signature.
    static func runningTeam() -> String? {
        var running: SecCode?
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
