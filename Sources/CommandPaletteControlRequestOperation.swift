/// The operation requested through the command-palette control bridge.
enum CommandPaletteControlRequestOperation {
    case list
    case run(commandID: String, arguments: [String: String], workingDirectory: String?)
}
