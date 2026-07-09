import CmuxSidebar
enum DockConfigurationLoadResult: Sendable {
    case resolved(DockConfigResolution)
    case failed(identity: DockConfigIdentity, message: String)
}
