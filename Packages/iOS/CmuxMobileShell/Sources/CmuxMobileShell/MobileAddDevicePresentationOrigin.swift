/// Owner of the shared Add Computer sheet presentation.
public enum MobileAddDevicePresentationOrigin: Equatable, Sendable {
    /// The user explicitly requested the sheet.
    case userInitiated
    /// First-connection discovery presented the sheet after an authoritative empty result.
    case automaticFirstConnection
    /// An attach ticket requires user approval in the sheet.
    case attachTicketApproval
}
