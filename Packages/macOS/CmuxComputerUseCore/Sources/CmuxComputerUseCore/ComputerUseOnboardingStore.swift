import Foundation
import Observation

/// Owns verified setup independently of window presentation and activity files.
@MainActor
@Observable
public final class ComputerUseOnboardingStore {
    public static let legacyCompletionKey = "cmux.computerUse.directCapture.ready"
    private let defaults: UserDefaults
    private let scope: String
    private var completionKey: String { "cmux.computerUse.onboarding.completion.\(scope)" }
    private var helperIdentity: String?
    private var verificationID = UUID()
    private var pendingVerificationID: UUID?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    public private(set) var completionCommitted = false
    public private(set) var phase = ComputerUseRuntimePermissionPhase.disabled(onboardingComplete: false) {
        didSet { if oldValue != phase { statusChanged() } }
    }

    public init(defaults: UserDefaults, scope: String) {
        self.defaults = defaults
        self.scope = scope
    }

    /// Coalesced snapshot invalidations for Settings and other observers.
    public func updates() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    public func statusChanged() {
        for continuation in subscribers.values { continuation.yield() }
    }

    public func apply(_ event: ComputerUseRuntimePermissionPhase.Event) {
        let next = phase.applying(event)
        guard next != phase else { return }
        verificationID = UUID()
        pendingVerificationID = nil
        phase = next
    }

    /// Restores evidence only for this runtime scope and helper identity.
    public func restore(for identity: String) {
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
        completionCommitted = complete
        defaults.removeObject(forKey: Self.legacyCompletionKey)
        switch phase {
        case .disabled:
            phase = .disabled(onboardingComplete: complete)
        case .onboardingRequired, .onboarding, .ready:
            phase = complete ? .ready : .onboardingRequired
        }
    }

    /// Invalidates evidence before replacing or re-provisioning a helper.
    public func invalidateHelper() {
        invalidateCompletion()
        helperIdentity = nil
    }

    /// Revocation or failed publication invalidates saved and in-flight evidence.
    public func invalidateCompletion() {
        verificationID = UUID()
        pendingVerificationID = nil
        completionCommitted = false
        phase = phase.applying(.helperReplaced)
        defaults.removeObject(forKey: completionKey)
        defaults.removeObject(forKey: Self.legacyCompletionKey)
    }

    public func beginVerification() -> UUID? {
        guard helperIdentity != nil else { return nil }
        if case .disabled = phase { return nil }
        return verificationID
    }

    /// Commits a successful verification for callers that do not need a
    /// multi-profile admission transaction.
    @discardableResult
    public func finishVerification(
        _ result: ComputerUseDirectScreenCaptureVerification,
        attempt: UUID
    ) -> ComputerUseDirectScreenCaptureVerification {
        guard stageVerification(result, attempt: attempt) == .ready else {
            return result
        }
        return commitVerification(attempt: attempt) ? .ready : .unavailable
    }

    /// Stages a successful capture in memory; it is not authorized until commit.
    @discardableResult
    public func stageVerification(
        _ result: ComputerUseDirectScreenCaptureVerification,
        attempt: UUID
    ) -> ComputerUseDirectScreenCaptureVerification {
        guard beginVerification() == attempt, result == .ready else {
            if result != .ready { invalidateCompletion() }
            return result == .ready ? .unavailable : result
        }
        pendingVerificationID = attempt
        phase = phase.applying(.onboardingCompleted)
        return .ready
    }

    /// Atomically records a staged verification after daemon publication.
    @discardableResult
    public func commitVerification(attempt: UUID) -> Bool {
        guard pendingVerificationID == attempt,
              phase.isReady,
              let helperIdentity else { return false }
        persistCompletion(for: helperIdentity)
        pendingVerificationID = nil
        completionCommitted = true
        statusChanged()
        return true
    }

    private func persistCompletion(for identity: String) {
        let record = ComputerUseOnboardingCompletion(version: 1, scope: scope, helperIdentity: identity)
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: completionKey)
        defaults.removeObject(forKey: Self.legacyCompletionKey)
    }
}
