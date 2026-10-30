import ArgumentParser

struct TextBoxCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: workspaceCompletion) var workspaceID: String?
    @Option(name: .customLong("surface"), completion: surfaceCompletion) var surfaceID: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var windowID: String?
    @Flag(name: .customLong("focus")) var focus = false
    @Argument(parsing: .allUnrecognized, completion: .list(["toggle", "show", "hide", "state"]))
    var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "textbox", helpNames: [])
}
