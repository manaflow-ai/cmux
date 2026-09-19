import Foundation
import Observation

/// Owns verified setup independently of window presentation and session activity files.
@MainActor
@Observable
final class ComputerUseOnboardingStore {
    static let legacyCompletionKey = "cmux.computerUse.directCapture.ready"
    private let defaults: UserDefaults
    private let scope: String
    private var completionKey: String { "cmux.computerUse.onboarding.completion.\(scope)" }
    private var helperIdentity: String?
    private var verificationID = UUID()
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
        verificationID = UUID()
        phase = next
    }

    /// Restores only evidence for this scope and the installed helper's code signature.
    /// Legacy completion is adopted only after the runtime compares the entire installed
    /// bundle with the shipped bundle. A missing/replaced helper never inherits it.
    func restore(for identity: String) {
        guard helperIdentity != identity else { return }
        verificationID = UUID()
        helperIdentity = identity
        var complete = false
        if let data = defaults.data(forKey: completionKey),
           let record = try? JSONDecoder().decode(ComputerUseOnboardingCompletion.self, from: data) {
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
    /// Restored records must also match the signing digest, so a crash cannot
    /// authorize replacement code even if the preferences invalidation was not flushed.
    func invalidateHelper() {
        invalidateCompletion()
        helperIdentity = nil
    }

    /// Revocation or failed publication invalidates both saved and in-flight evidence.
    func invalidateCompletion() {
        verificationID = UUID()
        phase = phase.applying(.helperReplaced)
        defaults.removeObject(forKey: completionKey)
        defaults.removeObject(forKey: Self.legacyCompletionKey)
    }

    func beginVerification() -> UUID? {
        guard helperIdentity != nil else { return nil }
        if case .disabled = phase { return nil }
        return verificationID
    }

    /// Commits only a current, explicitly requested, successful daemon capture probe.
    /// This synchronous MainActor transaction has no suspension between checking the
    /// generation, persisting the complete record, and authorizing tool admission.
    func finishVerification(
        _ result: ComputerUseDirectScreenCaptureVerification,
        attempt: UUID
    ) -> ComputerUseDirectScreenCaptureVerification {
        guard beginVerification() == attempt, let helperIdentity else { return .unavailable }
        guard result == .ready else {
            invalidateCompletion()
            return result
        }
        persistCompletion(for: helperIdentity)
        phase = phase.applying(.onboardingCompleted)
        return .ready
    }

    private func persistCompletion(for identity: String) {
        let record = ComputerUseOnboardingCompletion(version: 1, scope: scope, helperIdentity: identity)
        guard let data = try? JSONEncoder().encode(record) else { return }
        // One versioned preferences value, never independently written boolean fields.
        // A crash before preferences flush can lose completion and require setup again;
        // it cannot turn a partial record into authorization.
        defaults.set(data, forKey: completionKey)
        defaults.removeObject(forKey: Self.legacyCompletionKey)
    }
}
