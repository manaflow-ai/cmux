import Foundation

struct DockConfigResolution: Sendable {
    let controls: [DockControlDefinition]
    let sourceLocation: DockConfigLocation?
    let baseDirectory: String
    let isProjectSource: Bool
    let executionContext: DockExecutionContext

    var sourceURL: URL? { sourceLocation?.localURL }
    var sourcePath: String? { sourceLocation?.path }

    init(
        controls: [DockControlDefinition],
        sourceLocation: DockConfigLocation?,
        baseDirectory: String,
        isProjectSource: Bool,
        executionContext: DockExecutionContext
    ) {
        self.controls = controls
        self.sourceLocation = sourceLocation
        self.baseDirectory = baseDirectory
        self.isProjectSource = isProjectSource
        self.executionContext = executionContext
    }

    init(
        controls: [DockControlDefinition],
        sourceURL: URL?,
        baseDirectory: String,
        isProjectSource: Bool
    ) {
        self.init(
            controls: controls,
            sourceLocation: sourceURL.map { DockConfigLocation(origin: .local, path: $0.path) },
            baseDirectory: baseDirectory,
            isProjectSource: isProjectSource,
            executionContext: .local
        )
    }
}
