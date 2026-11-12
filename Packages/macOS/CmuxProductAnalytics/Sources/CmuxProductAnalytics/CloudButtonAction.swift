/// What a press of the sidebar footer Cloud button did.
public enum CloudButtonAction: String, Sendable, CaseIterable {
    /// Cloud was on: the press revealed Cloud Machines.
    case openCloud = "open_cloud"
    /// Cloud was off or signed out: the press also opened the welcome card.
    case introduceCloud = "introduce_cloud"
}
