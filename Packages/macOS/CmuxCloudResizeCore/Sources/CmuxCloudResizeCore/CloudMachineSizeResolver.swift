/// A server-advertised machine size that is safe for the client to display.
public struct CloudMachineSizeOption: Equatable, Sendable {
    /// Creates a validated machine size.
    ///
    /// - Parameters:
    ///   - memoryMb: Memory in MB. Must be positive.
    ///   - servedVcpus: The server's vCPU value for this memory size.
    ///   - servedDiskMb: The server's disk value for this memory size.
    ///   - fallbackDiskMb: The server's maximum disk value when no per-size disk is sent.
    ///   - useLegacyLadderFallback: Whether to use the pre-metadata size ladder.
    public init?(
        memoryMb: Int,
        servedVcpus: Int? = nil,
        servedDiskMb: Int? = nil,
        fallbackDiskMb: Int? = nil,
        useLegacyLadderFallback: Bool = false
    ) {
        guard memoryMb > 0 else { return nil }
        let vcpus = servedVcpus.flatMap { $0 > 0 ? $0 : nil }
        let disk = servedDiskMb.flatMap { $0 > 0 ? $0 : nil }
        let legacyDisk = useLegacyLadderFallback ? Self.legacyDiskMb(for: memoryMb) : nil
        let resolvedDisk = disk ?? legacyDisk ?? fallbackDiskMb ?? memoryMb
        let legacyVcpus = useLegacyLadderFallback ? Self.legacyVcpus(for: memoryMb) : nil

        self.memoryMb = memoryMb
        self.diskMb = resolvedDisk
        self.vcpus = vcpus ?? legacyVcpus ?? 0
    }

    /// Memory in MB.
    public let memoryMb: Int
    /// Disk in MB.
    public let diskMb: Int
    /// vCPUs advertised for this size, or zero when the server omitted it.
    public let vcpus: Int

    private static func legacyDiskMb(for memoryMb: Int) -> Int? {
        switch memoryMb {
        case 4_096: return 16_384
        case 8_192: return 32_768
        case 16_384: return 65_536
        case 24_576: return 98_304
        case 32_768, 65_536: return 131_072
        default: return nil
        }
    }

    private static func legacyVcpus(for memoryMb: Int) -> Int? {
        switch memoryMb {
        case 4_096: return 2
        case 8_192: return 4
        case 16_384: return 8
        case 24_576: return 12
        case 32_768: return 16
        case 65_536: return 32
        default: return nil
        }
    }
}

/// Resolves server size metadata while preserving compatibility with old responses.
public struct CloudMachineSizeResolver: Sendable {
    /// Creates a stateless size resolver.
    public init() {}

    /// Resolves one memory size from server metadata.
    ///
    /// - Parameters:
    ///   - memoryMb: Memory in MB.
    ///   - servedVcpus: The server's per-size vCPU map entry.
    ///   - servedDiskMb: The server's per-size disk map entry.
    ///   - fallbackDiskMb: The server's maximum disk value.
    ///   - useLegacyLadderFallback: Whether the response predates size metadata.
    /// - Returns: A validated size, or `nil` for non-positive memory.
    public func resolve(
        memoryMb: Int,
        servedVcpus: Int? = nil,
        servedDiskMb: Int? = nil,
        fallbackDiskMb: Int? = nil,
        useLegacyLadderFallback: Bool = false
    ) -> CloudMachineSizeOption? {
        CloudMachineSizeOption(
            memoryMb: memoryMb,
            servedVcpus: servedVcpus,
            servedDiskMb: servedDiskMb,
            fallbackDiskMb: fallbackDiskMb,
            useLegacyLadderFallback: useLegacyLadderFallback
        )
    }
}
