/// One process keeping the Mac or its display awake, mirrored from the Mac's
/// `mac.power.status` result (`CmuxMacPower.MacPowerAssertionHolder`).
public struct MobileMacPowerHolder: Decodable, Sendable, Equatable, Identifiable {
    /// The owning process id, or `0` when an older Mac host omits the field.
    public let pid: Int

    /// The owning process name, such as `caffeinate`, `cmux`, or a GUI app.
    public let processName: String

    /// The power assertion types this process currently holds.
    public let assertionTypes: [String]

    /// The optional assertion reason reported by the Mac host.
    public let detail: String?

    /// Stable per-row identity for SwiftUI lists.
    public var id: String {
        "\(pid)|\(processName)|\(assertionTypes.joined(separator: ","))|\(detail ?? "")"
    }

    private enum CodingKeys: String, CodingKey {
        case pid
        case processName = "process"
        case assertionTypes = "types"
        case detail
    }

    /// Decodes a holder from the Mac power-control wire payload.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = (try container.decodeIfPresent(Int.self, forKey: .pid)) ?? 0
        processName = (try container.decodeIfPresent(String.self, forKey: .processName)) ?? ""
        assertionTypes = (try container.decodeIfPresent([String].self, forKey: .assertionTypes)) ?? []
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
    }

    /// Creates a holder snapshot for tests and decoded Mac power status models.
    public init(pid: Int, processName: String, assertionTypes: [String], detail: String?) {
        self.pid = pid
        self.processName = processName
        self.assertionTypes = assertionTypes
        self.detail = detail
    }
}
