public import CmuxNextWakeups
public import Foundation
import Security

/// Checks a pack item with `SecStaticCodeCheckValidity`: strict validation,
/// every architecture, nested code (a helper app's executable, the
/// framework's libraries), against the requirement
/// `anchor apple generic and certificate leaf[subject.OU] = "<team>"`
/// (a Developer ID certificate of that team).
///
/// The check reads and hashes every file of the item and waits on the
/// Security daemons, so it runs on `work`'s system lane, never on the
/// caller's thread (Chrome posts such work with `base::MayBlock()`,
/// base/task/task_traits.h).
public struct SecCodeChromiumRuntimeSignatureChecker: ChromiumRuntimeSignatureChecking {
    private let work: BackgroundWork

    /// Creates a checker that validates on `work`'s system lane (the app's one ``BackgroundWork``).
    public init(work: BackgroundWork) {
        self.work = work
    }

    public func check(_ item: URL, teamID: String) async throws(ChromiumRuntimeInstallError) {
        let failure: ChromiumRuntimeInstallError?
        do {
            failure = try await work.run(.userVisible, mayBlock: .system) { Self.validate(item, teamID: teamID) }
        } catch {
            // Cancelled, or dropped by shutdown before it ran: nothing vouched for the item.
            throw .signature(item.lastPathComponent)
        }
        if let failure { throw failure }
    }

    /// The Security framework calls, on the lane: nil when `item` is validly signed by `teamID`, else why not.
    private static func validate(_ item: URL, teamID: String) -> ChromiumRuntimeInstallError? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(item as CFURL, [], &code) == errSecSuccess, let code else {
            return .signature(item.lastPathComponent)
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return .signature("requirement for \(teamID)")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            return .signature(item.lastPathComponent)
        }
        return nil
    }
}
