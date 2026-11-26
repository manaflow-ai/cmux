/// The captured behavior of a `Button`, evaluated when the button is tapped
/// by a host runtime.
public struct ButtonAction: Codable, Sendable, Equatable {
    public let commands: [ActionCommand]

    public init(commands: [ActionCommand]) {
        self.commands = commands
    }
}
