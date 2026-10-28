public import CmuxNextWakeups
public import Foundation
public import Security

/// Checks a pack item's code signature on disk: strict validation, every
/// architecture, nested code (a helper app's executable, the framework's
/// libraries), against the requirement
/// `anchor apple generic and certificate leaf[subject.OU] = "<team>"`
/// (a Developer ID certificate of that team).
///
/// The check reads and hashes every file of the item and waits on the
/// Security daemons, so it runs on `work`'s system lane, never on the
/// caller's thread (Chrome posts such work with `base::MayBlock()`,
/// base/task/task_traits.h). The check itself is injected: the App passes its
/// kept-per-version check (CmuxNextCompat's `StaticCodeValidityCache`, over the
/// checked static code validity seam), so the load after an install does not
/// hash the same pack again.
public struct SecCodeChromiumRuntimeSignatureChecker: ChromiumRuntimeSignatureChecking {
    /// Whether the code at a URL is valid under the flags and satisfies the requirement text. It blocks.
    public typealias Validity = @Sendable (URL, SecCSFlags, String) -> Bool

    private let work: BackgroundWork
    private let isValid: Validity

    /// Creates a checker that runs `isValid` on `work`'s system lane (the app's one ``BackgroundWork``).
    public init(work: BackgroundWork, isValid: @escaping Validity) {
        self.work = work
        self.isValid = isValid
    }

    public func check(_ item: URL, teamID: String,
                      priority: ChromiumRuntimeInstaller.Priority) async throws(ChromiumRuntimeInstallError) {
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let valid: Bool
        do {
            valid = try await work.run(Self.lanePriority(priority), mayBlock: .system) { [isValid] in isValid(item, flags, requirement) }
        } catch {
            // The only error `run` throws for a non-throwing body: the item never ran (the caller was cancelled
            // or quit dropped it), so nothing vouched for it, and it is no signature failure either.
            throw .cancelled
        }
        guard valid else { throw .signature(item.lastPathComponent) }
    }

    /// The lane priority of an install job's check. A background prefetch is work nobody waits for, as Chrome's
    /// component installs post their unpack and verify at `BEST_EFFORT` (components/update_client/task_traits.h);
    /// a person's request is user-visible. `run` still raises it to an awaiting caller's priority.
    static func lanePriority(_ priority: ChromiumRuntimeInstaller.Priority) -> WorkPriority {
        switch priority {
        case .background: .bestEffort
        case .user: .userVisible
        }
    }
}
