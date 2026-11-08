public import Foundation

/// Stable identity for one logical task submission.
///
/// A retry reuses the same identity. Any edit that changes the requested task
/// rotates it so the Mac cannot mistake a new request for the previous one.
public struct MobileTaskSubmissionIdentity: Equatable, Sendable {
    private struct ResolvedRequest: Equatable, Sendable {
        let snapshot: MobileTaskSubmissionSnapshot?
        let id: UUID
    }

    /// Identity sent with `workspace.create`.
    public private(set) var id: UUID
    private var baseline: ResolvedRequest
    private var divergent: ResolvedRequest?
    private var active: ResolvedRequest
    public private(set) var needsRequestResolution = false

    /// Creates an identity, restoring `id` for a retry when one exists.
    public init(
        id: UUID = UUID(),
        initialRequest: MobileTaskSubmissionSnapshot? = nil
    ) {
        self.id = id
        let resolved = ResolvedRequest(
            snapshot: initialRequest?.withOperationID(id),
            id: id
        )
        self.baseline = resolved
        self.active = resolved
    }

    /// Starts a distinct logical submission after composer input changes.
    public mutating func rotate() {
        let newID = UUID()
        id = newID
        active = ResolvedRequest(
            snapshot: active.snapshot?.withOperationID(newID),
            id: newID
        )
        baseline = active
        divergent = nil
        needsRequestResolution = false
    }

    /// Defers all request composition and equivalence work until a persistence
    /// or submission boundary. Calling this for each keystroke is O(1).
    public mutating func markRequestDirty() {
        guard !needsRequestResolution else { return }
        needsRequestResolution = true
    }

    /// Builds and compares the request only at persistence or send boundaries.
    /// A clean retry returns the cached request without evaluating `builder`.
    public mutating func resolveCurrentRequest(
        _ builder: () -> MobileTaskSubmissionSnapshot?
    ) -> MobileTaskSubmissionSnapshot? {
        guard needsRequestResolution else { return active.snapshot }

        let candidate = builder()
        let resolvedID: UUID
        if Self.requestsAreEquivalent(candidate, baseline.snapshot) {
            resolvedID = baseline.id
        } else if let divergent,
                  Self.requestsAreEquivalent(candidate, divergent.snapshot) {
            resolvedID = divergent.id
        } else {
            resolvedID = UUID()
            divergent = ResolvedRequest(
                snapshot: candidate?.withOperationID(resolvedID),
                id: resolvedID
            )
        }

        let resolved = ResolvedRequest(
            snapshot: candidate?.withOperationID(resolvedID),
            id: resolvedID
        )
        id = resolvedID
        active = resolved
        needsRequestResolution = false
        return resolved.snapshot
    }

    /// Treats a submitted snapshot as the new retry baseline after failure.
    public mutating func adoptResolvedRequest(_ snapshot: MobileTaskSubmissionSnapshot) {
        id = snapshot.operationID
        let resolved = ResolvedRequest(snapshot: snapshot, id: snapshot.operationID)
        baseline = resolved
        active = resolved
        divergent = nil
        needsRequestResolution = false
    }

    private static func requestsAreEquivalent(
        _ lhs: MobileTaskSubmissionSnapshot?,
        _ rhs: MobileTaskSubmissionSnapshot?
    ) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            lhs.isRequestEquivalent(to: rhs)
        case (nil, nil):
            true
        default:
            false
        }
    }
}
