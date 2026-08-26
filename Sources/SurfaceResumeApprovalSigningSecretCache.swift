import Foundation

/// Resolves the surface-resume signing secret once without making main-thread
/// callers wait for Keychain or filesystem I/O.
///
/// A `nil` result is cached deliberately. Without an explicit ready state,
/// every autosave tick would retry `SecItemCopyMatching` for every terminal
/// panel when Keychain access fails.
final class SurfaceResumeApprovalSigningSecretCache: @unchecked Sendable {
    private typealias Completion = @Sendable (Data?) -> Void

    private enum State {
        case unresolved
        case loading([Completion], Task<Void, Never>?)
        case ready(Data?)
    }

    private let lock = NSLock()
    private let loader: @Sendable () -> Data?
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Never>?
    private var state: State = .unresolved

    init(
        loader: @escaping @Sendable () -> Data?,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Never>?
    ) {
        self.loader = loader
        self.schedule = schedule
    }

    deinit {
        let task: Task<Void, Never>? = lock.withLock {
            guard case let .loading(_, task) = state else { return nil }
            return task
        }
        task?.cancel()
    }

    static func utilityTask(_ job: @escaping @Sendable () -> Void) -> Task<Void, Never> {
#if compiler(>=6.2)
        let operation: @concurrent @Sendable () async -> Void = {
            job()
        }
#else
        let operation: @Sendable () async -> Void = {
            job()
        }
#endif
        return Task.detached(priority: .utility, operation: operation)
    }

    /// Returns the cached secret or starts its one-time resolution.
    ///
    /// Main-thread callers always return immediately. A background caller may
    /// perform the first resolution synchronously; callers arriving while that
    /// resolution is in flight observe `.pending` until it completes.
    func value(isMainThread: Bool) -> SurfaceResumeApprovalSigningSecretResolution {
        let decision: ValueDecision = lock.withLock {
            switch state {
            case .unresolved:
                state = .loading([], nil)
                return isMainThread ? .schedule : .load
            case .loading:
                return .return(.pending)
            case let .ready(value):
                return .return(.ready(value))
            }
        }

        switch decision {
        case let .return(value):
            return value
        case .schedule:
            let task = schedule { [weak self] in
                self?.resolve()
            }
            retainScheduledTask(task)
            return .pending
        case .load:
            return .ready(resolve())
        }
    }

    var isReady: Bool {
        lock.withLock {
            guard case .ready = state else { return false }
            return true
        }
    }

    /// Resolves the secret if needed and calls `completion` exactly once after
    /// the result (including a cached `nil`) becomes authoritative.
    func preload(completion: @escaping @Sendable (Data?) -> Void) {
        let decision: PreloadDecision = lock.withLock {
            switch state {
            case .unresolved:
                state = .loading([completion], nil)
                return .schedule
            case let .loading(completions, task):
                state = .loading(completions + [completion], task)
                return .none
            case let .ready(value):
                return .complete(completion, value)
            }
        }

        switch decision {
        case .schedule:
            let task = schedule { [weak self] in
                self?.resolve()
            }
            retainScheduledTask(task)
        case let .complete(completion, value):
            completion(value)
        case .none:
            break
        }
    }

    @discardableResult
    private func resolve() -> Data? {
        let value = loader()
        let completions: [Completion] = lock.withLock {
            let completions: [Completion]
            if case let .loading(pending, _) = state {
                completions = pending
            } else {
                completions = []
            }
            state = .ready(value)
            return completions
        }
        completions.forEach { $0(value) }
        return value
    }

    private func retainScheduledTask(_ task: Task<Void, Never>?) {
        guard let task else { return }
        let shouldCancel = lock.withLock {
            guard case let .loading(completions, nil) = state else { return true }
            state = .loading(completions, task)
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private enum ValueDecision {
        case `return`(SurfaceResumeApprovalSigningSecretResolution)
        case schedule
        case load
    }

    private enum PreloadDecision {
        case schedule
        case none
        case complete(Completion, Data?)
    }
}

extension SurfaceResumeApprovalStore {
    static func validRecords(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data
    ) -> [SurfaceResumeApprovalRecord] {
        loadRecords(fileURL: fileURL, fileManager: fileManager)
            .filter { $0.hasValidSignature(secret: signingSecret) }
    }

    static func validRecordsLookup(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalLookup<[SurfaceResumeApprovalRecord]> {
        validRecordsLookup(
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution(
                explicit: signingSecret,
                fileManager: fileManager
            )
        )
    }

    static func validRecordsLookup(
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecretResolution: SurfaceResumeApprovalSigningSecretResolution
    ) -> SurfaceResumeApprovalLookup<[SurfaceResumeApprovalRecord]> {
        switch signingSecretResolution {
        case .pending:
            return .pendingSigningSecret
        case let .ready(signingSecret):
            guard let signingSecret else { return .resolved([]) }
            return .resolved(validRecords(
                fileURL: fileURL,
                fileManager: fileManager,
                signingSecret: signingSecret
            ))
        }
    }

    static func matchingRecord(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data
    ) -> SurfaceResumeApprovalRecord? {
        bestRecord(
            in: validRecords(fileURL: fileURL, fileManager: fileManager, signingSecret: signingSecret),
            matching: binding
        )
    }

    static func matchingRecordLookup(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalLookup<SurfaceResumeApprovalRecord?> {
        matchingRecordLookup(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution(
                explicit: signingSecret,
                fileManager: fileManager
            )
        )
    }

    static func matchingRecordLookup(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecretResolution: SurfaceResumeApprovalSigningSecretResolution
    ) -> SurfaceResumeApprovalLookup<SurfaceResumeApprovalRecord?> {
        switch validRecordsLookup(
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution
        ) {
        case .pendingSigningSecret:
            return .pendingSigningSecret
        case let .resolved(records):
            return .resolved(bestRecord(in: records, matching: binding))
        }
    }

    static func applyingStoredApproval(
        to binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data
    ) -> SurfaceResumeBindingSnapshot {
        if let trustedBinding = trustedBinding(from: binding) {
            return trustedBinding
        }

        let record = matchingRecord(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecret: signingSecret
        )
        return bindingByApplying(record: record, to: binding)
    }

    static func applyingStoredApprovalLookup(
        to binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalLookup<SurfaceResumeBindingSnapshot> {
        applyingStoredApprovalLookup(
            to: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution(
                explicit: signingSecret,
                fileManager: fileManager
            )
        )
    }

    static func applyingStoredApprovalLookup(
        to binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecretResolution: SurfaceResumeApprovalSigningSecretResolution
    ) -> SurfaceResumeApprovalLookup<SurfaceResumeBindingSnapshot> {
        if let trustedBinding = trustedBinding(from: binding) {
            return .resolved(trustedBinding)
        }

        switch matchingRecordLookup(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution
        ) {
        case .pendingSigningSecret:
            return .pendingSigningSecret
        case let .resolved(record):
            return .resolved(bindingByApplying(record: record, to: binding))
        }
    }

    /// Resolves approval inputs for a proposal without gating trusted sources on the signing secret.
    static func approvalProposalContext(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalLookup<(
        effectiveBinding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?
    )> {
        approvalProposalContext(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution(
                explicit: signingSecret,
                fileManager: fileManager
            )
        )
    }

    static func approvalProposalContext(
        for binding: SurfaceResumeBindingSnapshot,
        fileURL: URL = defaultURL(),
        fileManager: FileManager = .default,
        signingSecretResolution: SurfaceResumeApprovalSigningSecretResolution
    ) -> SurfaceResumeApprovalLookup<(
        effectiveBinding: SurfaceResumeBindingSnapshot,
        existingRecord: SurfaceResumeApprovalRecord?
    )> {
        if let trustedBinding = trustedBinding(from: binding) {
            return .resolved((trustedBinding, nil))
        }

        switch matchingRecordLookup(
            for: binding,
            fileURL: fileURL,
            fileManager: fileManager,
            signingSecretResolution: signingSecretResolution
        ) {
        case .pendingSigningSecret:
            return .pendingSigningSecret
        case let .resolved(record):
            return .resolved((bindingByApplying(record: record, to: binding), record))
        }
    }

    static func isValid(_ record: SurfaceResumeApprovalRecord, signingSecret: Data) -> Bool {
        record.hasValidSignature(secret: signingSecret)
    }

    static func isValidLookup(
        _ record: SurfaceResumeApprovalRecord,
        signingSecret: Data? = nil
    ) -> SurfaceResumeApprovalLookup<Bool> {
        switch signingSecretResolution(explicit: signingSecret, fileManager: .default) {
        case .pending:
            return .pendingSigningSecret
        case let .ready(signingSecret):
            guard let signingSecret else { return .resolved(false) }
            return .resolved(isValid(record, signingSecret: signingSecret))
        }
    }

    static func signingSecretResolution(
        explicit signingSecret: Data?,
        fileManager: FileManager
    ) -> SurfaceResumeApprovalSigningSecretResolution {
        if let signingSecret {
            return .ready(signingSecret)
        }
        return defaultSigningSecret(fileManager: fileManager)
    }

    static func bindingWithoutStoredApproval(
        to binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        trustedBinding(from: binding) ?? bindingByApplying(record: nil, to: binding)
    }

    private static func trustedBinding(
        from binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot? {
        if binding.isProcessDetected {
            var trustedBinding = binding
            trustedBinding.autoResume = true
            trustedBinding.approvalPolicy = .auto
            trustedBinding.approvalRecordId = nil
            return trustedBinding
        }
        if binding.isAgentHookBinding {
            var trustedBinding = binding
            trustedBinding.autoResume = binding.autoResume == true
            trustedBinding.approvalPolicy = trustedBinding.autoResume == true ? .auto : .manual
            trustedBinding.approvalRecordId = nil
            return trustedBinding
        }
        return nil
    }

    private static func bestRecord(
        in records: [SurfaceResumeApprovalRecord],
        matching binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeApprovalRecord? {
        records
            .filter { $0.matches(binding) }
            .sorted { lhs, rhs in
                if lhs.commandPrefix.count != rhs.commandPrefix.count {
                    return lhs.commandPrefix.count > rhs.commandPrefix.count
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private static func bindingByApplying(
        record: SurfaceResumeApprovalRecord?,
        to binding: SurfaceResumeBindingSnapshot
    ) -> SurfaceResumeBindingSnapshot {
        var effective = binding
        guard let record else {
            effective.autoResume = false
            effective.approvalPolicy = .manual
            effective.approvalRecordId = nil
            return effective
        }
        effective.approvalPolicy = record.policy
        effective.approvalRecordId = record.id
        effective.autoResume = record.policy == .auto
        return effective
    }
}
