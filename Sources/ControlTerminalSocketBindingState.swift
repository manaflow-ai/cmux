/// Product-facing relationship between a workspace panel and its socket target.
enum ControlTerminalSocketBindingState: String {
    case bound
    case registryRebound = "registry_rebound"
    case unavailable
}
