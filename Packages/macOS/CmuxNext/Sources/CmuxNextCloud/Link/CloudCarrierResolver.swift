public import Foundation

/// The carrier's link of a Cloud machine (design/cloud-carrier.md): no local socket and no app-server op.
/// Each daemon connection runs its own `cmux carrier dial --service mux` (``CloudCarrierDial``), which
/// mints the ticket, resumes a paused machine and refuses with its own code, so a connect only opens the
/// ``CloudLinkSession``'s ticket. The owner answer is the machine record's: its creator is the caller.
public struct CloudCarrierResolver: CloudLinkResolver {
    private let ownership: @Sendable () async -> CloudCallerOwnership

    /// `ownership`: the signed-in caller and the machine, read at each connect.
    public init(ownership: @escaping @Sendable () async -> CloudCallerOwnership) {
        self.ownership = ownership
    }

    public func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        let caller = await ownership()
        return CloudLinkSocket(key: key, path: "", generation: nil, callerOwnsVM: caller == .owner, callerIsTeammate: caller == .team)
    }

    /// Nothing to close: each dial ends with its connection.
    public func close(_ key: CloudLinkKey) async {}
}

extension CloudCallerOwnership {
    /// The record's rule (cloud-machine-ops.ts `CloudVmKind`): the machine's creator is its `owner`, any
    /// other member of its team is `team`; unknown while either id is missing.
    public init(creator: String?, caller: String?) {
        guard let creator, let caller, !creator.isEmpty, !caller.isEmpty else { self = .unknown; return }
        self = creator == caller ? .owner : .team
    }
}
