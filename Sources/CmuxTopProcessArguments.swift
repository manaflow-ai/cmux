import CMUXAgentLaunch

typealias CmuxTopProcessArguments = AgentProcessArguments
typealias CmuxTopProcessFilterMetadata = AgentProcessFilterMetadata

extension CmuxTopProcessSnapshot {
    static func processArgumentsAndEnvironment(for pid: Int) -> CmuxTopProcessArguments? {
        AgentProcessArgumentsParser().argumentsAndEnvironment(for: pid)
    }

    static func processArgumentsAndEnvironment(
        fromKernProcArgs bytes: [UInt8]
    ) -> CmuxTopProcessArguments? {
        AgentProcessArgumentsParser().argumentsAndEnvironment(fromKernProcArgs: bytes)
    }

    static func processProjectWorkingDirectory(fromKernProcArgs bytes: [UInt8]) -> String? {
        AgentProcessArgumentsParser().projectWorkingDirectory(fromKernProcArgs: bytes)
    }

    static func processFilterMetadata(
        fromKernProcArgs bytes: [UInt8],
        normalizedArgumentNeedles: [[UInt8]]
    ) -> CmuxTopProcessFilterMetadata? {
        AgentProcessArgumentsParser().filterMetadata(
            fromKernProcArgs: bytes,
            normalizedArgumentNeedles: normalizedArgumentNeedles
        )
    }

    static func kernProcArgsBytes(for pid: Int) -> [UInt8]? {
        AgentProcessArgumentsParser().kernProcArgsBytes(for: pid)
    }
}
