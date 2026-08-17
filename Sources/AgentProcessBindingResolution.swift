enum AgentProcessBindingResolution: String, Sendable {
    case corroborated
    case controllingTTY = "controlling_tty"
}

enum AgentTTYBindingResolution: String, Sendable {
    case reportedTTY = "reported_tty"
}
