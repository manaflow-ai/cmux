public import Foundation

public enum MobileEventStreamTerminationReason: Equatable, Sendable {
    case bufferOverflow
    case transportClosed
    case cancelled
}

final class MobileEventStreamTerminationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MobileEventStreamTerminationReason?

    func finish(_ reason: MobileEventStreamTerminationReason) {
        lock.lock()
        if value == nil { value = reason }
        lock.unlock()
    }

    var reason: MobileEventStreamTerminationReason? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class MobileEventRetentionLease: @unchecked Sendable {
    private let release: @Sendable () -> Void

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    deinit {
        release()
    }
}

public struct MobileEventStream: AsyncSequence, Sendable {
    public typealias Element = MobileEventEnvelope
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let base: AsyncStream<Element>
    private let terminationState: MobileEventStreamTerminationState

    init(base: AsyncStream<Element>, terminationState: MobileEventStreamTerminationState) {
        self.base = base
        self.terminationState = terminationState
    }

    public func makeAsyncIterator() -> AsyncIterator {
        base.makeAsyncIterator()
    }

    public var terminationReason: MobileEventStreamTerminationReason? {
        terminationState.reason
    }
}

/// One server-pushed event delivered over the persistent transport.
public struct MobileEventEnvelope: Sendable {
    /// The event topic (matches a subscription topic).
    public let topic: String
    /// The event payload as raw JSON, if present.
    public let payloadJSON: Data?
    /// The associated stream identifier, if the event carries one.
    public let streamID: String?
    /// The surface identifier extracted while the event envelope is parsed.
    /// This lets consumers establish per-surface ordering before decoding a
    /// potentially large payload away from the UI actor.
    public let surfaceID: String?
    private let retentionLease: MobileEventRetentionLease?

    /// Creates an event envelope.
    /// - Parameters:
    ///   - topic: The event topic.
    ///   - payloadJSON: The raw JSON payload, if any.
    ///   - streamID: The associated stream identifier, if any.
    ///   - surfaceID: The routed terminal surface, if the payload carries one.
    public init(topic: String, payloadJSON: Data?, streamID: String?, surfaceID: String? = nil) {
        self.topic = topic
        self.payloadJSON = payloadJSON
        self.streamID = streamID
        self.surfaceID = surfaceID
        self.retentionLease = nil
    }

    func retaining(_ lease: MobileEventRetentionLease) -> Self {
        Self(
            topic: topic,
            payloadJSON: payloadJSON,
            streamID: streamID,
            surfaceID: surfaceID,
            retentionLease: lease
        )
    }

    private init(
        topic: String,
        payloadJSON: Data?,
        streamID: String?,
        surfaceID: String?,
        retentionLease: MobileEventRetentionLease
    ) {
        self.topic = topic
        self.payloadJSON = payloadJSON
        self.streamID = streamID
        self.surfaceID = surfaceID
        self.retentionLease = retentionLease
    }
}

extension MobileEventEnvelope {
    static func parsing(topic: String, payload: Any?, streamID: String?) -> Self {
        let payloadJSON = payload.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let payloadObject = payload as? [String: Any]
        let renderGridObject = payloadObject?["render_grid"] as? [String: Any]
        let surfaceID = (payloadObject?["surface_id"] as? String)
            ?? (renderGridObject?["surface_id"] as? String)
        return Self(
            topic: topic,
            payloadJSON: payloadJSON,
            streamID: streamID,
            surfaceID: surfaceID
        )
    }
}
