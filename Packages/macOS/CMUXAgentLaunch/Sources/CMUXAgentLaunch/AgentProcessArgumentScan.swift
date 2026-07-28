/// A single process scan that defers full argument decoding until needed.
public struct AgentProcessArgumentScan {
    /// Process identifiers admitted for full decoding.
    public let candidateProcessIDs: Set<Int>

    private let injectedArgumentsProvider: ((Int) -> AgentProcessArguments?)?
    private let processArgumentBytesProvider: (Int) -> [UInt8]?
    private let processArgumentsDecoder: ([UInt8]) -> AgentProcessArguments?
    private let selectorIsExhaustive: Bool
    private var rawProcessArgumentsByPID: [Int: [UInt8]]
    private var processArgumentsByPID: [Int: AgentProcessArguments?] = [:]

    /// Plans one scan and retains raw buffers only for admitted processes.
    ///
    /// - Parameters:
    ///   - processes: Scoped process projections for this scan.
    ///   - selector: The selector that owns candidate and raw metadata policy.
    ///   - injectedArgumentsProvider: An optional decoded-argument provider.
    ///     Supplying one preserves exhaustive semantics for tests and specialized callers.
    ///   - processArgumentBytesProvider: Reads a process's raw `KERN_PROCARGS2` bytes.
    ///   - processArgumentsDecoder: Fully decodes one retained raw buffer.
    ///   - additionalMetadataRequiresFullDecode: Admits metadata for an
    ///     app-owned rule, such as a project-local registration.
    public init(
        processes: [AgentProcessCandidate],
        selector: AgentProcessCandidateSelector,
        injectedArgumentsProvider: ((Int) -> AgentProcessArguments?)?,
        processArgumentBytesProvider: @escaping (Int) -> [UInt8]?,
        processArgumentsDecoder: @escaping ([UInt8]) -> AgentProcessArguments?,
        additionalMetadataRequiresFullDecode: (AgentProcessFilterMetadata?) -> Bool
    ) {
        var candidateProcessIDs = selector.processIDs
        let usesInjectedArguments = injectedArgumentsProvider != nil
        if usesInjectedArguments {
            candidateProcessIDs = Set(processes.map(\.processID))
        }

        let selectorIsExhaustive = candidateProcessIDs.count == processes.count
        var rawProcessArgumentsByPID: [Int: [UInt8]] = [:]
        if !usesInjectedArguments, !selectorIsExhaustive {
            for process in processes {
                guard let bytes = processArgumentBytesProvider(process.processID) else {
                    continue
                }
                let metadata = selector.rawMetadata(fromKernProcArgs: bytes)
                if additionalMetadataRequiresFullDecode(metadata) {
                    candidateProcessIDs.insert(process.processID)
                }
                if !candidateProcessIDs.contains(process.processID),
                   let metadata,
                   selector.rawMetadataMayRequireFullDecode(metadata, process: process) {
                    candidateProcessIDs.insert(process.processID)
                }
                if candidateProcessIDs.contains(process.processID) {
                    rawProcessArgumentsByPID[process.processID] = bytes
                }
            }
        }

        self.candidateProcessIDs = candidateProcessIDs
        self.injectedArgumentsProvider = injectedArgumentsProvider
        self.processArgumentBytesProvider = processArgumentBytesProvider
        self.processArgumentsDecoder = processArgumentsDecoder
        self.selectorIsExhaustive = selectorIsExhaustive
        self.rawProcessArgumentsByPID = rawProcessArgumentsByPID
    }

    /// Returns decoded arguments for an admitted process, memoized for this scan.
    ///
    /// - Parameter processID: The Darwin process identifier.
    /// - Returns: Decoded arguments, or `nil` when the process was rejected,
    ///   disappeared, or had a malformed argument buffer.
    public mutating func arguments(for processID: Int) -> AgentProcessArguments? {
        guard candidateProcessIDs.contains(processID) else { return nil }
        if let cached = processArgumentsByPID[processID] {
            return cached
        }

        let resolved: AgentProcessArguments?
        if let injectedArgumentsProvider {
            resolved = injectedArgumentsProvider(processID)
        } else if let bytes = rawProcessArgumentsByPID.removeValue(forKey: processID) {
            resolved = processArgumentsDecoder(bytes)
        } else if selectorIsExhaustive,
                  let bytes = processArgumentBytesProvider(processID) {
            resolved = processArgumentsDecoder(bytes)
        } else {
            resolved = nil
        }
        processArgumentsByPID.updateValue(resolved, forKey: processID)
        return resolved
    }
}
