import Foundation

struct DockConfigResolution: Sendable {
    let controls: [DockControlDefinition]
    let sourceURL: URL?
    let baseDirectory: String
    let isProjectSource: Bool
}
