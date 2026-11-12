/// The coordinator state required to construct a correctly configured mobile
/// Simulator frame reader.
public struct MobileSimulatorReaderReadiness: Equatable {
    public let transportName: String
    public let displayScale: Double

    public init?(transportName: String?, displayScale: Double?) {
        guard let transportName, let displayScale else { return nil }
        self.transportName = transportName
        self.displayScale = displayScale
    }
}

/// Owns reader attachment identity so failed construction remains retryable.
public struct MobileSimulatorReaderAttachment<Reader> {
    public init() {}

    public enum Refresh {
        case unchanged
        case missing(detached: Reader?)
        case attached(reader: Reader, detached: Reader?)

        public var detachedReader: Reader? {
            switch self {
            case .unchanged:
                nil
            case let .missing(detached), let .attached(_, detached):
                detached
            }
        }

        public var attachedReader: Reader? {
            guard case let .attached(reader, _) = self else { return nil }
            return reader
        }

        public var isMissing: Bool {
            guard case .missing = self else { return false }
            return true
        }
    }

    public private(set) var reader: Reader?
    private var attachedReadiness: MobileSimulatorReaderReadiness?

    public mutating func refresh(
        for readiness: MobileSimulatorReaderReadiness?,
        makeReader: () -> Reader?
    ) -> Refresh {
        if let readiness,
           reader != nil,
           attachedReadiness == readiness {
            return .unchanged
        }

        let detached = reader
        reader = nil
        attachedReadiness = nil

        guard let readiness else {
            return detached == nil ? .unchanged : .missing(detached: detached)
        }
        guard let reader = makeReader() else {
            return .missing(detached: detached)
        }

        self.reader = reader
        attachedReadiness = readiness
        return .attached(reader: reader, detached: detached)
    }

    public mutating func detach() -> Reader? {
        defer {
            reader = nil
            attachedReadiness = nil
        }
        return reader
    }
}
