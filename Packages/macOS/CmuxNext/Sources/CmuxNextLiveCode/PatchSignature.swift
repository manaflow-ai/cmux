// Who may publish a patch (cmux#13742): outside Debug and bench, a live code build signed by a team
// loads a patch only when it is signed, validly, by that same team, so an ad hoc or a stranger's
// dylib in the live folder never runs. An app with no team (unsigned or ad hoc: it can be neither
// notarized nor distributed, and code of its user could rewrite it anyway) loads any validly signed
// patch, ad hoc included, and says so in its log. Whether it has a team comes only from the running
// process's own code signature, never from Info.plist, the environment or defaults.
//
// The check reads a file and dlopen maps it again later, so a process of the same user could swap
// the file in between. A team's app therefore loads patches only while the kernel enforces library
// validation on it (hardened runtime, no disable-library-validation entitlement): dyld then maps
// only code of the app's own team, whatever file it opens, and this check is the early refusal with
// a reason. A team's app without it refuses every patch.
import Foundation
import Security

nonisolated enum PatchSignature {
    /// Who signed the running app, from its own code signature.
    enum AppSigner: Equatable, Sendable {
        /// Signed by this team (its ten-character ID).
        case team(String)
        /// Unsigned or ad hoc: the signature names no team.
        case noTeam
        /// Signed by a team, but library validation is off, so a patch swapped in after the check
        /// would load: every patch is refused.
        case unprotected(team: String, why: String)
        /// The app's own signature could not be read: every patch is refused.
        case unreadable(String)
    }

    /// Throws unless `path` is validly signed by `app`'s team, or, for an app with no team, validly
    /// signed at all. Off the main thread: it reads and hashes the file.
    static func check(_ path: String, app: AppSigner = runningSigner()) throws {
        let team: String?
        switch app {
        case .unreadable(let detail):
            throw LiveCodeError.notOurTeam("the app's own signature is unreadable: \(detail)")
        case .unprotected(let id, let why):
            throw LiveCodeError.notOurTeam("the app (team \(id)) runs without library validation (\(why))")
        case .noTeam:
            team = nil
        case .team(let id):
            // A team ID is ten capitals and digits; anything else never goes into the requirement text.
            guard id.utf8.count == 10, id.utf8.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
                throw LiveCodeError.notOurTeam("the app's team ID \(id) is malformed")
            }
            team = id
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            throw LiveCodeError.notOurTeam("unreadable signature")
        }
        // Apple-anchored (a Developer ID or Apple Development certificate) and the same team; for an
        // app with no team, no requirement past a valid signature.
        var requirement: SecRequirement?
        if let team {
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
            guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, requirement != nil else {
                throw LiveCodeError.notOurTeam("no requirement for team \(team)")
            }
        }
        // concurrency-allow: called only from LiveEngine, an actor off the main thread
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else {
            throw LiveCodeError.notOurTeam(team.map { "team \($0) required (OSStatus \(status))" } ?? "no valid signature (OSStatus \(status))")
        }
    }

    /// The running app's signer, from its own code signature (SecCodeCopySelf) and the kernel's
    /// status of this process.
    static func runningSigner() -> AppSigner {
        var running: SecCode?
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running else { return .unreadable("SecCodeCopySelf failed") }
        guard SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else { return .unreadable("no static code") }
        let wanted = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, wanted, &info) == errSecSuccess,
              let values = info as? [String: Any] else { return .unreadable("no signing information") }
        var flags = SecCodeStatus()
        let status: UInt32? = SecCodeGetStatus(running, [], &flags) == errSecSuccess ? flags.rawValue : nil
        return signer(team: values[kSecCodeInfoTeamIdentifier as String] as? String, status: status,
                      entitlements: values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:])
    }

    /// The kernel's code signing status bits (`cs_blobs.h`): library validation required, and the
    /// hardened runtime, which requires it unless an entitlement turns it off.
    static let requireLibraryValidation: UInt32 = 0x2000
    static let hardenedRuntime: UInt32 = 0x10000

    /// The signer from what the signature says: its team, the process's status bits and the app's
    /// entitlements. A team's app counts only with library validation on.
    static func signer(team: String?, status: UInt32?, entitlements: [String: Any]) -> AppSigner {
        guard let team, !team.isEmpty else { return .noTeam }
        guard let status else { return .unprotected(team: team, why: "its code signing status is unreadable") }
        if entitlements["com.apple.security.cs.disable-library-validation"] as? Bool == true {
            return .unprotected(team: team, why: "it has the disable-library-validation entitlement")
        }
        guard status & (requireLibraryValidation | hardenedRuntime) != 0 else {
            return .unprotected(team: team, why: "neither the hardened runtime nor library validation is on")
        }
        return .team(team)
    }
}
