import Foundation

/// A point-in-time reading from the machine daemon or a resource resize reply.
/// Sleeping machines are never woken for a reading: they come back `asleep` with
/// only their provisioned memory.
struct VMStats: Equatable, Sendable {
    let state: State
    let sampledAt: Date
    var resourceSampledAt: Date? = nil
    let cpus: Int?
    let cpuPercent: Double?
    let loadAverage1m: Double?
    let memoryTotalMb: Int?
    let memoryUsedMb: Int?
    let diskTotalMb: Int?
    let diskUsedMb: Int?
}

extension VMStats {
    /// A failed poll has completed without a sample; it is no longer loading.
    static func unavailable(at date: Date = .now) -> Self {
        Self(
            state: .unknown, sampledAt: date,
            cpus: nil, cpuPercent: nil, loadAverage1m: nil,
            memoryTotalMb: nil, memoryUsedMb: nil,
            diskTotalMb: nil, diskUsedMb: nil
        )
    }

    /// Decodes both stats and resize replies, including the pre-timestamp telemetry contract.
    init(json: [String: Any], now: Date = .now) {
        func number(_ key: String) -> Double? {
            guard let number = json[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        func integer(_ key: String) -> Int? {
            number(key).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        }
        let sampledAt = number("sampledAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        let cpu = number("cpuPercent")
        let memory = integer("memoryUsedMb")
        let disk = integer("diskUsedMb")
        // Before resourceSampledAt existed, sampledAt accompanied real gauges.
        // A dimensions-only response must never be treated as a guest sample.
        let hasGauges = cpu != nil || memory != nil || disk != nil
        let resourceDate = number("resourceSampledAt").map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? (hasGauges ? sampledAt : nil)
        self.init(
            state: State(rawValue: json["state"] as? String ?? "") ?? .unknown,
            sampledAt: sampledAt ?? now, resourceSampledAt: resourceDate,
            cpus: integer("cpus"), cpuPercent: cpu, loadAverage1m: number("loadAverage1m"),
            memoryTotalMb: integer("memoryTotalMb"), memoryUsedMb: memory,
            diskTotalMb: integer("diskTotalMb"), diskUsedMb: disk
        )
    }
}
