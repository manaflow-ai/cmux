/// The final notification admission lane after focus and workspace-mute gates.
enum TerminalNotificationArrivalDisposition: Equatable, Sendable {
    case externalDelivery
    case focusedInline
    case muted

    var suppressesPhoneForward: Bool {
        self != .externalDelivery
    }
}
