#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxHomeCore
public import CmuxNextCloud
public import Foundation

/// Inputs for an isolated Home composition test, using the app's source protocol
/// and account type. This does not simulate sign-in, token leasing, entitlements,
/// a remote daemon, or a running Chief. AppServices captures separately require
/// the auth-capture fixture; these inputs only replace the values Home consumes.
@MainActor
public struct HomeCompositionDependencies {
    public let source: any HomeSource
    public let me: ParticipantID
    public let user: CMUXAuthUser?
    public let stackProjectID: String
    public let chiefHome: ChiefHome
    public let caches: URL
    /// Installed harness IDs and their existing doctor result (true means ready).
    public let harnesses: [String: Bool]

    public init(source: any HomeSource, me: ParticipantID, user: CMUXAuthUser?, stackProjectID: String,
                chiefHome: ChiefHome, caches: URL, harnesses: [String: Bool]) {
        self.source = source
        self.me = me
        self.user = user
        self.stackProjectID = stackProjectID
        self.chiefHome = chiefHome
        self.caches = caches
        self.harnesses = harnesses
    }

    public var account: String? {
        user.map { CloudIdentity.workerUserID(stackProjectID: stackProjectID, stackUserID: $0.id) }
    }
}
#endif
