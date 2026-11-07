internal import Foundation

/// Validates only transport shapes and budgets; SVG interpretation stays app-side.
struct ControlSurfaceIconParser {
    struct Invalid: Error {
        let message: String
    }

    func parse(_ params: [String: JSONValue], clear: Bool) throws -> ControlSurfaceIconInputs {
        try knownKeys(params, allowed: [
            "workspace_id", "surface_id", "owner_id", "lease_token", "expected_revision",
            "expected_agent_pid", "expected_process_start", "ttl_seconds", "asset",
        ])
        let workspaceID = try uuid(params["workspace_id"], name: "workspace_id")
        let surfaceID = try uuid(params["surface_id"], name: "surface_id")
        let ownerID = try string(params["owner_id"], name: "owner_id", maxBytes: 200)
        let token = try params["lease_token"].map { try uuid($0, name: "lease_token") }
        let revision = try params["expected_revision"].map {
            try integer($0, name: "expected_revision", range: 1...Int.max)
        }
        let pid = try params["expected_agent_pid"].map {
            try integer($0, name: "expected_agent_pid", range: 1...Int.max)
        }
        let processStart = try params["expected_process_start"].map {
            try string($0, name: "expected_process_start", maxBytes: 80)
        }
        let ttl = try params["ttl_seconds"].map {
            try integer($0, name: "ttl_seconds", range: 5...120)
        } ?? 30
        let asset: ControlSurfaceIconAsset?
        if clear {
            guard params["asset"] == nil else { throw invalid("asset is not valid for clear") }
            asset = nil
        } else {
            guard pid != nil, processStart != nil else {
                throw invalid("set requires expected_agent_pid and expected_process_start")
            }
            if let rawAsset = params["asset"] {
                asset = try parseAsset(rawAsset)
            } else {
                guard token != nil else { throw invalid("asset is required unless renewing a lease_token") }
                asset = nil
            }
        }
        return ControlSurfaceIconInputs(
            operation: clear ? .clear : .set,
            workspaceID: workspaceID, surfaceID: surfaceID, ownerID: ownerID,
            leaseToken: token, expectedRevision: revision, expectedAgentPID: pid,
            expectedProcessStart: processStart, ttlSeconds: ttl, asset: asset
        )
    }

    private func parseAsset(_ value: JSONValue) throws -> ControlSurfaceIconAsset {
        guard case .object(let object) = value else { throw invalid("asset must be an object") }
        try knownKeys(object, allowed: ["frames", "loop", "static_frame"])
        guard case .array(let rawFrames) = object["frames"], (1...64).contains(rawFrames.count) else {
            throw invalid("asset.frames must contain 1 through 64 frames")
        }
        guard case .bool(let loop) = object["loop"] else { throw invalid("asset.loop must be a boolean") }
        let staticFrame = try object["static_frame"].map {
            try integer($0, name: "asset.static_frame", range: 0...(rawFrames.count - 1))
        } ?? 0
        var frames: [ControlSurfaceIconFrame] = []
        var totalBytes = 0
        var totalDuration = 0
        for rawFrame in rawFrames {
            guard case .object(let frame) = rawFrame else { throw invalid("each frame must be an object") }
            try knownKeys(frame, allowed: ["svg", "duration_ms"])
            let svg = try string(frame["svg"], name: "frame.svg", maxBytes: 16 * 1024)
            let duration = try integer(frame["duration_ms"], name: "frame.duration_ms", range: 50...5000)
            totalBytes += svg.utf8.count
            totalDuration += duration
            guard totalBytes <= 512 * 1024 else { throw invalid("asset SVG total exceeds 512 KiB") }
            guard totalDuration <= 30_000 else { throw invalid("asset duration exceeds 30000 ms") }
            frames.append(ControlSurfaceIconFrame(svg: svg, durationMS: duration))
        }
        return ControlSurfaceIconAsset(frames: frames, loop: loop, staticFrame: staticFrame)
    }

    private func knownKeys(_ object: [String: JSONValue], allowed: Set<String>) throws {
        guard object.keys.allSatisfy({ allowed.contains($0) }) else {
            throw invalid("unknown parameter")
        }
    }

    private func uuid(_ value: JSONValue?, name: String) throws -> UUID {
        guard case .string(let string) = value,
              string.utf8.count == 36,
              let id = UUID(uuidString: string),
              id.uuidString.lowercased() == string.lowercased() else {
            throw invalid("\(name) must be an explicit UUID")
        }
        return id
    }

    private func string(_ value: JSONValue?, name: String, maxBytes: Int) throws -> String {
        guard case .string(let string) = value,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.utf8.count <= maxBytes else {
            throw invalid("\(name) must be a nonempty string of at most \(maxBytes) UTF-8 bytes")
        }
        return string
    }

    /// Exact conversions reject booleans, strings, fractions, and non-finite or overflowing numbers.
    private func integer(_ value: JSONValue?, name: String, range: ClosedRange<Int>) throws -> Int {
        let parsed: Int?
        switch value {
        case .int(let number): parsed = Int(exactly: number)
        case .double(let number): parsed = Int(exactly: number)
        default: parsed = nil
        }
        guard let parsed, range.contains(parsed) else {
            throw invalid("\(name) must be an integer from \(range.lowerBound) through \(range.upperBound)")
        }
        return parsed
    }

    private func invalid(_ message: String) -> Invalid { Invalid(message: message) }
}
