public import CmuxNextCompat

/// A snapshot of every registered memory consumer and the inputs of its limit: what each one holds
/// (footprint and volatile bytes, entries), its traits and the limit the coordinator gives it, and
/// the pressure level, Memory Saver mode and budget the limits come from.
///
/// ``MemoryCoordinator/report(budget:)`` makes it in one pass over the consumers. `debug.memory` serves it
/// and `memory-report.py` joins it with the process footprint, so the bytes that no consumer
/// claims show as unattributed.
///
/// ## Chrome reference
///
/// Chrome's memory-infra: each subsystem is a `base::trace_event::MemoryDumpProvider`
/// (`base/trace_event/memory_dump_provider.h`) that reports its own allocator dumps
/// (`base/trace_event/memory_allocator_dump.h`: a name, a size and an object count), and the
/// dump manager collects them in one pass. cmux differs in one way: a consumer that cannot tell
/// its size reports `nil`, which the report keeps as unknown (`null` in JSON, "unknown" in text),
/// never as 0, so a missing measurement cannot pass for an empty cache.
public nonisolated struct MemoryReport: Codable, Hashable, Sendable {
    /// The pressure level the limits come from (the debug override when one is set).
    public let level: MemoryPressureLevel
    /// The Memory Saver mode the limits come from.
    public let mode: MemorySaverMode
    /// The budgets at normal pressure, sized from physical memory.
    public let budget: SubsystemBudget
    /// Every live consumer, in the coordinator's release order (``MemoryReleaseOrder``, then
    /// registration order).
    public let consumers: [Consumer]

    /// A report of `consumers` under `level`, `mode` and `budget`.
    public init(level: MemoryPressureLevel, mode: MemorySaverMode, budget: SubsystemBudget, consumers: [Consumer]) {
        self.level = level
        self.mode = mode
        self.budget = budget
        self.consumers = consumers
    }

    /// One registered consumer: its name, traits, current limit and what it holds.
    public nonisolated struct Consumer: Codable, Hashable, Sendable {
        /// The name the consumer registered with (Chrome's consumer ID).
        public let name: String
        /// The traits the consumer registered with.
        public let traits: MemoryConsumerTraits
        /// The limit the coordinator gives the consumer now.
        public let limit: MemoryLimit
        /// Bytes the consumer holds that count in `phys_footprint`; `nil` when unknown.
        public let footprintBytes: Int?
        /// Purgeable bytes the kernel can take back without asking; `nil` when unknown.
        public let volatileBytes: Int?
        /// Objects the consumer holds (cache entries, pages, surfaces); `nil` when unknown.
        public let entries: Int?

        /// A row for a consumer whose usage is `usage`; `nil` usage reports every count as unknown.
        public init(name: String, traits: MemoryConsumerTraits, limit: MemoryLimit, usage: MemoryUsage?) {
            self.init(
                name: name,
                traits: traits,
                limit: limit,
                footprintBytes: usage?.footprintBytes,
                volatileBytes: usage?.volatileBytes,
                entries: usage?.entries
            )
        }

        /// A row with each count given; `nil` is unknown.
        public init(
            name: String,
            traits: MemoryConsumerTraits,
            limit: MemoryLimit,
            footprintBytes: Int?,
            volatileBytes: Int?,
            entries: Int?
        ) {
            self.name = name
            self.traits = traits
            self.limit = limit
            self.footprintBytes = footprintBytes
            self.volatileBytes = volatileBytes
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case traits
            case limit
            case footprintBytes = "footprint_bytes"
            case volatileBytes = "volatile_bytes"
            case entries
        }

        /// Reads a row; a count that is missing or `null` is unknown.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decode(String.self, forKey: .name),
                traits: try container.decode(MemoryConsumerTraits.self, forKey: .traits),
                limit: try container.decode(MemoryLimit.self, forKey: .limit),
                footprintBytes: try container.decodeIfPresent(Int.self, forKey: .footprintBytes),
                volatileBytes: try container.decodeIfPresent(Int.self, forKey: .volatileBytes),
                entries: try container.decodeIfPresent(Int.self, forKey: .entries)
            )
        }

        /// Writes every count, an unknown one as `null`, so a reader sees unknown rather than a
        /// missing key it might read as 0.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(traits, forKey: .traits)
            try container.encode(limit, forKey: .limit)
            try container.encode(footprintBytes, forKey: .footprintBytes)
            try container.encode(volatileBytes, forKey: .volatileBytes)
            try container.encode(entries, forKey: .entries)
        }
    }
}

nonisolated extension MemoryReport: CustomStringConvertible {
    /// One line for the inputs, then one line per consumer; an unknown count reads "unknown".
    public var description: String {
        var lines = ["level \(level.rawValue), mode \(mode.rawValue), \(consumers.count) consumers"]
        for consumer in consumers {
            lines.append(
                "\(consumer.name): footprint \(Self.text(consumer.footprintBytes)) B, "
                    + "volatile \(Self.text(consumer.volatileBytes)) B, "
                    + "entries \(Self.text(consumer.entries)), limit \(consumer.limit.percent) %"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func text(_ count: Int?) -> String {
        count.map(String.init) ?? "unknown"
    }
}

nonisolated extension SubsystemBudget: Codable {
    private enum CodingKeys: String, CodingKey {
        case physicalMiB = "physical_mib"
        case gpuResidentAvailable = "gpu_resident_available"
        case chromiumRendererLimit = "chromium_renderer_limit"
        case warmTerminalSurfaces = "warm_terminal_surfaces"
        case parkedWorkspaces = "parked_workspaces"
        case parkedIdleTimeoutSeconds = "parked_idle_timeout_seconds"
        case imageCacheBytes = "image_cache_bytes"
        case homeRenderBitmapBytes = "home_render_bitmap_bytes"
        case hibernationSnapshotBytes = "hibernation_snapshot_bytes"
        case liveHiddenAgentPages = "live_hidden_agent_pages"
        case liveHiddenInternalPages = "live_hidden_internal_pages"
        case kittyImageBytesPerSurface = "kitty_image_bytes_per_surface"
        case webProcessPagesPerGroup = "web_process_pages_per_group"
    }

    /// Reads every field as the report holds it, so a report from a build with other formulas
    /// decodes to the budgets that build had.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        physicalMiB = try container.decode(Int.self, forKey: .physicalMiB)
        gpuResidentAvailable = try container.decode(Bool.self, forKey: .gpuResidentAvailable)
        chromiumRendererLimit = try container.decode(Int.self, forKey: .chromiumRendererLimit)
        warmTerminalSurfaces = try container.decode(Int.self, forKey: .warmTerminalSurfaces)
        parkedWorkspaces = try container.decode(Int.self, forKey: .parkedWorkspaces)
        parkedIdleTimeout = .seconds(try container.decode(Int64.self, forKey: .parkedIdleTimeoutSeconds))
        imageCacheBytes = try container.decode(Int.self, forKey: .imageCacheBytes)
        homeRenderBitmapBytes = try container.decode(Int.self, forKey: .homeRenderBitmapBytes)
        hibernationSnapshotBytes = try container.decode(Int.self, forKey: .hibernationSnapshotBytes)
        liveHiddenAgentPages = try container.decode(Int.self, forKey: .liveHiddenAgentPages)
        liveHiddenInternalPages = try container.decode(Int.self, forKey: .liveHiddenInternalPages)
        kittyImageBytesPerSurface = try container.decode(Int.self, forKey: .kittyImageBytesPerSurface)
        webProcessPagesPerGroup = try container.decode(Int.self, forKey: .webProcessPagesPerGroup)
    }

    /// Writes the inputs and every budget a report reader shows.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(physicalMiB, forKey: .physicalMiB)
        try container.encode(gpuResidentAvailable, forKey: .gpuResidentAvailable)
        try container.encode(chromiumRendererLimit, forKey: .chromiumRendererLimit)
        try container.encode(warmTerminalSurfaces, forKey: .warmTerminalSurfaces)
        try container.encode(parkedWorkspaces, forKey: .parkedWorkspaces)
        try container.encode(parkedIdleTimeout.components.seconds, forKey: .parkedIdleTimeoutSeconds)
        try container.encode(imageCacheBytes, forKey: .imageCacheBytes)
        try container.encode(homeRenderBitmapBytes, forKey: .homeRenderBitmapBytes)
        try container.encode(hibernationSnapshotBytes, forKey: .hibernationSnapshotBytes)
        try container.encode(liveHiddenAgentPages, forKey: .liveHiddenAgentPages)
        try container.encode(liveHiddenInternalPages, forKey: .liveHiddenInternalPages)
        try container.encode(kittyImageBytesPerSurface, forKey: .kittyImageBytesPerSurface)
        try container.encode(webProcessPagesPerGroup, forKey: .webProcessPagesPerGroup)
    }
}
