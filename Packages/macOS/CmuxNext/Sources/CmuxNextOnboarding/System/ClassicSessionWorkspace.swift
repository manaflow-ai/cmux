import Foundation

/// One workspace eligible for import into cmux-next.
public struct ClassicSessionWorkspace: Codable, Equatable, Sendable {
    public let name: String
    public let workingDirectory: String
    public let layout: ClassicSessionLayout

    public init(name: String, workingDirectory: String, layout: ClassicSessionLayout) {
        self.name = name
        self.workingDirectory = workingDirectory
        self.layout = layout
    }
}

