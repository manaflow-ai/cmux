struct DockProjectConfigSource: Sendable {
    let origin: DockConfigOrigin
    let fileSystem: any DockConfigFileSystem
    let rootDirectory: DockConfigPath
    let boundaryDirectory: DockConfigPath
    let executionContext: DockExecutionContext
}
