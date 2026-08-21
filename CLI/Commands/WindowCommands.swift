import ArgumentParser
import Foundation

/// Routes window facade declarations through the established CLI implementation.
private protocol LegacyWindowCommand: ParsableCommand {}

extension LegacyWindowCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol WindowTargetCommand: LegacyWindowCommand {}

extension WindowTargetCommand {
    static var window: CompletionKind {
        .custom(CompletionCandidates.windows)
    }
}

struct ListWindowsCommand: LegacyWindowCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list-windows", helpNames: [])
}

struct CurrentWindowCommand: LegacyWindowCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "current-window", helpNames: [])
}

struct NewWindowCommand: LegacyWindowCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "new-window", helpNames: [])
}

struct FocusWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "focus-window", helpNames: [])
}

struct CloseWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "close-window", helpNames: [])
}

struct FindWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Flag(name: .customLong("content")) var content = false
    @Flag(name: .customLong("select")) var select = false
    @Argument(parsing: .allUnrecognized) var query: [String] = []
    static let configuration = CommandConfiguration(commandName: "find-window", helpNames: [])
}

struct NextWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "next-window", helpNames: [])
}

struct PreviousWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "previous-window", helpNames: [])
}

struct LastWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "last-window", helpNames: [])
}

struct RenameWindowCommand: WindowTargetCommand {
    @Option(name: .customLong("workspace"), completion: .custom(CompletionCandidates.workspaces)) var workspace: String?
    @Option(name: .customLong("window"), completion: window) var target: String?
    @Argument(parsing: .allUnrecognized) var title: [String] = []
    static let configuration = CommandConfiguration(commandName: "rename-window", helpNames: [])
}
