import Foundation
import Observation

/// Owns verified setup independently of window presentation and session activity files.
@MainActor
@Observable
final class ComputerUseOnboardingStore {
    struct Verification: Equatable {
        fileprivate let generation: Int
        fileprivate let helperIdentity: String
    }

    private struct Completion: Codable {
        let version: Int
        let scope: String
        let helperIdentity: String
    }

    static let legacyCompletionKey = "cmux.computerUse.directCapture.ready"
    private let defaults: UserDefaults
    private let scope: String
    private var completionKey: String { "cmux.computerUse.onboarding.completion.\(scope)" }
    private var helperIdentity: String?
    private var generation = 0
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private(set) var phase = ComputerUseRuntimePermissionPhase.disabled(onboardingComplete: false) {
        didSet { if oldValue != phase { statusChanged() } }
    }

    init(defaults: UserDefaults, scope: String) {
        self.defaults = defaults
        self.scope = scope
    }

    deinit {
        for continuation in subscribers.values { continuation.finish() }
    }

    /// Coalesced snapshot invalidations, including daemon acknowledgements and TCC changes.
    /// Settings consumes these without starting another permission probe or setup flow.
    func updates() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func statusChanged() {
        for continuation in subscribers.values { continuation.yield() }
    }

    func apply(_ event: ComputerUseRuntimePermissionPhase.Event) {
        let next = phase.applying(event)
        guard next != phase else { return }
        generation &+= 1
        phase = next
    }

    /// Restores only evidence for this scope and the installed helper's code signature.
    /// Legacy completion is adopted only after the runtime compares the entire installed
    /// bundle with the shipped bundle. A missing/replaced helper never inherits it.
    func restore(for identity: String) {
        guard helperIdentity != identity else { return }
        generation &+= 1
        helperIdentity = identity
        var complete = false
        if let data = defaults.data(forKey: completionKey),
           let record = try? JSONDecoder().decode(Completion.self, from: data) {
            complete = record.version == 1 && record.scope == scope && record.helperIdentity == identity
        } else if defaults.object(forKey: completionKey) == nil,
                  defaults.bool(forKey: Self.legacyCompletionKey) {
            persistCompletion(for: identity)
            complete = true
        }
        defaults.removeObject(forKey: Self.legacyCompletionKey)
        switch phase {
        case .disabled:
            phase = .disabled(onboardingComplete: complete)
        case .onboardingRequired, .onboarding, .ready:
            phase = complete ? .ready : .onboardingRequired
        }
    }

    /// Must run before replacing or re-provisioning a helper, including a missing copy.
    /// A crash at any later installation step cannot revive an old completion record.
    func invalidateHelper() {
        generation &+= 1
        helperIdentity = nil
        phase = phase.applying(.helperReplaced)
        defaults.removeObject(forKey: completionKey)
        defaults.removeObject(forKey: Self.legacyCompletionKey)
    }

    /// A confirmed revocation invalidates capture evidence without forgetting identity.
    func permissionsRevoked() {
        guard phase.isReady else { return }
        let identity = helperIdentity
        invalidateHelper()
        helperIdentity = identity
    }

    func beginVerification() -> Verification? {
        guard let helperIdentity else { return nil }
        if case .disabled = phase { return nil }
        return Verification(generation: generation, helperIdentity: helperIdentity)
    }

    /// Commits only a current, explicitly requested, successful daemon capture probe.
    /// This synchronous MainActor transaction has no suspension between checking the
    /// generation, persisting the complete record, and authorizing tool admission.
    func finishVerification(
        _ result: ComputerUseDirectScreenCaptureVerification,
        attempt: Verification
    ) -> ComputerUseDirectScreenCaptureVerification {
        guard beginVerification() == attempt else { return .unavailable }
        guard result == .ready else { return result }
        persistCompletion(for: attempt.helperIdentity)
        phase = phase.applying(.onboardingCompleted)
        return .ready
    }

    private func persistCompletion(for identity: String) {
        let record = Completion(version: 1, scope: scope, helperIdentity: identity)
        guard let data = try? JSONEncoder().encode(record) else { return }
        // One versioned preferences value, never independently written boolean fields.
        // A crash before preferences flush can lose completion and require setup again;
        // it cannot turn a partial record into authorization.
        defaults.set(data, forKey: completionKey)
        defaults.removeObject(forKey: Self.legacyCompletionKey)
    }
}
