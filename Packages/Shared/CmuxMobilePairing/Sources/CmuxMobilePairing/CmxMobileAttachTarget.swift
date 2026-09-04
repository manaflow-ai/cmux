/// The consumer of a newly minted mobile attach ticket.
public enum CmxMobileAttachTarget: String, CaseIterable, Sendable {
    /// Keep the complete authenticated ticket for an RPC-only caller.
    case ticketOnly = "ticket_only"
    /// Prefer an identity-only Iroh ticket, falling back to a local loopback route.
    case simulatorInjection = "simulator_injection"
    /// Keep every authenticated route a physical iPhone can use.
    case physicalDevice = "physical_device"

    /// Creates a target from a case-insensitive wire value.
    ///
    /// - Parameter wireValue: The value received from a pairing request.
    /// - Returns: The matching target, or `nil` for an unknown value.
    public init?(wireValue: String) {
        self.init(rawValue: wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
