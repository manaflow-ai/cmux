public import Foundation

public enum ControlSimulatorTargetFailure: Sendable, Equatable {
    case tabManagerUnavailable
    case workspaceNotFound
    case remoteWorkspace
    case surfaceNotFound(UUID?)
    case surfaceNotSimulator(UUID)
    case simulatorNotFound
    case ambiguousSimulatorSurfaces(Int)
}

public enum ControlSimulatorTypeStartResolution: Sendable {
    case started(
        surfaceID: UUID,
        characterCount: Int,
        completionTimeoutSeconds: TimeInterval,
        receipt: ControlSimulatorCompletionReceipt
    )
    case failed(ControlSimulatorTargetFailure)
    case emptyText
    case textTooLong(maximumUTF8ByteCount: Int)
    case unsupportedCharacter(scalarIndex: Int, scalarValue: UInt32)
    case inputUnavailable
    case deliveryUnavailable
}

public enum ControlSimulatorCompletion: Sendable, Equatable {
    case succeeded
    case failed
}

/// Bridges an async worker acknowledgement to one socket-worker request.
public final class ControlSimulatorCompletionReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private var completion: ControlSimulatorCompletion?

    public init() {}

    public func complete(_ completion: ControlSimulatorCompletion) {
        condition.lock()
        defer { condition.unlock() }
        guard self.completion == nil else { return }
        self.completion = completion
        condition.broadcast()
    }

    public func wait(timeout: TimeInterval) -> ControlSimulatorCompletion? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while completion == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return completion
    }
}

public struct ControlSimulatorWebInspectorTargetSnapshot: Sendable, Equatable {
    public let id: String
    public let applicationIdentifier: String
    public let pageIdentifier: UInt64
    public let title: String
    public let url: String
    public let type: String
    public let applicationName: String
    public let bundleIdentifier: String?
    public let isInUse: Bool

    public init(
        id: String,
        applicationIdentifier: String,
        pageIdentifier: UInt64,
        title: String,
        url: String,
        type: String,
        applicationName: String,
        bundleIdentifier: String?,
        isInUse: Bool
    ) {
        self.id = id
        self.applicationIdentifier = applicationIdentifier
        self.pageIdentifier = pageIdentifier
        self.title = title
        self.url = url
        self.type = type
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.isInUse = isInUse
    }
}

public enum ControlSimulatorWebInspectorSessionSnapshot: Sendable, Equatable {
    case detached
    case attached(sessionID: UUID, targetID: String)
}

public struct ControlSimulatorWebInspectorSnapshot: Sendable, Equatable {
    public let surfaceID: UUID
    public let targets: [ControlSimulatorWebInspectorTargetSnapshot]
    public let session: ControlSimulatorWebInspectorSessionSnapshot
    public let isHighlighted: Bool

    public init(
        surfaceID: UUID,
        targets: [ControlSimulatorWebInspectorTargetSnapshot],
        session: ControlSimulatorWebInspectorSessionSnapshot,
        isHighlighted: Bool
    ) {
        self.surfaceID = surfaceID
        self.targets = targets
        self.session = session
        self.isHighlighted = isHighlighted
    }
}

public enum ControlSimulatorWebInspectorSnapshotResolution: Sendable, Equatable {
    /// The snapshot is immediate; `refreshAccepted` means a fresh async read was started.
    case snapshot(ControlSimulatorWebInspectorSnapshot, refreshAccepted: Bool)
    case failed(ControlSimulatorTargetFailure)
    case unavailable
}

public enum ControlSimulatorWebInspectorMutationResolution: Sendable, Equatable {
    /// The main actor accepted the operation; worker completion remains asynchronous.
    case accepted(surfaceID: UUID)
    case failed(ControlSimulatorTargetFailure)
    case unavailable
    case targetNotFound(String)
    case sessionDetached
}

public enum ControlSimulatorWebInspectorCompletion: Sendable, Equatable {
    case targets(ControlSimulatorWebInspectorSnapshot)
    case session(ControlSimulatorWebInspectorSessionSnapshot)
    case highlighted(Bool)
    case released
    case response(json: String, truncated: Bool)
    case failed(code: String, message: String)
}

public final class ControlSimulatorWebInspectorReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private var completion: ControlSimulatorWebInspectorCompletion?

    public init() {}

    public func complete(_ completion: ControlSimulatorWebInspectorCompletion) {
        condition.lock()
        defer { condition.unlock() }
        guard self.completion == nil else { return }
        self.completion = completion
        condition.broadcast()
    }

    public func wait(timeout: TimeInterval) -> ControlSimulatorWebInspectorCompletion? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while completion == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return completion
    }
}

public enum ControlSimulatorWebInspectorStartResolution: Sendable {
    case started(
        surfaceID: UUID,
        timeoutSeconds: TimeInterval,
        receipt: ControlSimulatorWebInspectorReceipt
    )
    case failed(ControlSimulatorTargetFailure)
    case unavailable
    case targetNotFound(String)
    case sessionDetached
}
