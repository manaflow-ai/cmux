/// The coordinator state required to construct a correctly configured mobile
/// Simulator frame reader.
struct MobileSimulatorReaderReadiness: Equatable {
    let transportName: String
    let displayScale: Double

    init?(transportName: String?, displayScale: Double?) {
        guard let transportName, let displayScale else { return nil }
        self.transportName = transportName
        self.displayScale = displayScale
    }
}

/// Owns reader attachment identity so failed construction remains retryable.
struct MobileSimulatorReaderAttachment<Reader> {
    enum Refresh {
        case unchanged
        case missing(detached: Reader?)
        case attached(reader: Reader, detached: Reader?)

        var detachedReader: Reader? {
            switch self {
            case .unchanged:
                nil
            case let .missing(detached), let .attached(_, detached):
                detached
            }
        }

        var attachedReader: Reader? {
            guard case let .attached(reader, _) = self else { return nil }
            return reader
        }

        var isMissing: Bool {
            guard case .missing = self else { return false }
            return true
        }
    }

    private(set) var reader: Reader?
    private var attachedReadiness: MobileSimulatorReaderReadiness?

    mutating func refresh(
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

    mutating func detach() -> Reader? {
        defer {
            reader = nil
            attachedReadiness = nil
        }
        return reader
    }
}
