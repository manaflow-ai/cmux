enum DockControlVariant: Equatable, Sendable {
    case command(String)
    case terminal
    case browser(url: String, profile: String?)
}
