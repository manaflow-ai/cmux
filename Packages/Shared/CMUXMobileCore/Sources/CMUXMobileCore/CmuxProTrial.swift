import Foundation

/// The Pro free trial an account is on, from the Cloud service's
/// `/api/billing/plan` `trial` object.
///
/// The service runs a trial on a limited allowance (one machine, a small
/// size and a small number of VM-hours) and names it Pro, never Go. Every
/// surface that names the plan says "Pro trial" and offers no upgrade while
/// the trial runs: full Pro starts when the trial converts.
public struct CmuxProTrial: Sendable, Equatable, Decodable {
    /// What the trial includes, from `trial.limits`. A field the service did
    /// not send (or sent as something other than a positive whole number)
    /// is `nil`, and surfaces then state the standard trial allowance.
    public struct Limits: Sendable, Equatable {
        /// Machines the trial can keep.
        public let machines: Int?
        /// vCPUs of the trial machine.
        public let vcpus: Int?
        /// Memory of the trial machine, in GB.
        public let memoryGb: Int?
        /// VM-hours the trial includes.
        public let vmHours: Int?

        /// Creates trial limits; `nil` marks a value the service did not send.
        public init(machines: Int? = nil, vcpus: Int? = nil, memoryGb: Int? = nil, vmHours: Int? = nil) {
            self.machines = machines
            self.vcpus = vcpus
            self.memoryGb = memoryGb
            self.vmHours = vmHours
        }
    }

    /// When the trial ends, or `nil` when the service did not say.
    public let endsAt: Date?
    /// What the trial includes, as the service reported it.
    public let limits: Limits

    /// Creates a trial snapshot.
    ///
    /// - Parameters:
    ///   - endsAt: When the trial ends, or `nil` when unknown.
    ///   - limits: What the trial includes; defaults to nothing reported.
    public init(endsAt: Date?, limits: Limits = Limits()) {
        self.endsAt = endsAt
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey { case endsAt, limits }
    private enum LimitKeys: String, CodingKey { case machines, vcpus, memoryGb, vmHours }

    /// Decodes the plan response's `trial` object. It never fails on a
    /// malformed field: such a field reads as unknown, so a bad value cannot
    /// break the whole plan response.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endsAt = Self.endDate(fromISO8601: try? container.decodeIfPresent(String.self, forKey: .endsAt))
        let raw = try? container.nestedContainer(keyedBy: LimitKeys.self, forKey: .limits)
        func number(_ key: LimitKeys) -> Int? {
            guard let value = (try? raw?.decodeIfPresent(Double.self, forKey: key)) ?? nil,
                  value.isFinite, value > 0, value == value.rounded(), value < Double(Int32.max) else { return nil }
            return Int(value)
        }
        limits = Limits(machines: number(.machines), vcpus: number(.vcpus), memoryGb: number(.memoryGb), vmHours: number(.vmHours))
    }

    /// Reads the `trial.endsAt` value of a plan response: an ISO 8601
    /// timestamp with or without fractional seconds. Anything else is unknown.
    ///
    /// - Parameter value: The raw `endsAt` string, or `nil`.
    /// - Returns: The parsed date, or `nil` when the value is absent or unreadable.
    public static func endDate(fromISO8601 value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
