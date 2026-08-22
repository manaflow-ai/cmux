import ArgumentParser
import Foundation

struct ListWindowsCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-windows", helpNames: [])
}

struct CurrentWindowCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "current-window", helpNames: [])
}

struct NewWindowCommand: SharedLegacyFacadeCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-window", helpNames: [])
}

struct FocusWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-window", helpNames: [])
}

struct CloseWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close-window", helpNames: [])
}

struct FindWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Flag(name: .customLong("content")) var content = false
    @Flag(name: .customLong("select")) var select = false
    @Argument(parsing: .allUnrecognized) var query: [String] = []
    static let configuration = CommandConfiguration(commandName: "find-window", helpNames: [])
}

struct NextWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "next-window", helpNames: [])
}

struct PreviousWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "previous-window", helpNames: [])
}

struct LastWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "last-window", helpNames: [])
}

struct RenameWindowCommand: SharedLegacyFacadeCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: windowCompletion) var target: String?
    @Argument(parsing: .allUnrecognized) var title: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename-window", helpNames: [])
}
