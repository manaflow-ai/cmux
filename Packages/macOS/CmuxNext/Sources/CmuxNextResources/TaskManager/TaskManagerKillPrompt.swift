import Foundation

/// The question Kill Process asks before it ends a process.
public struct TaskManagerKillPrompt: Sendable, Equatable {
    public var title: String
    public var body: String
    public var button: String

    /// The question for the process `name` (`pid`).
    public init(name: String, pid: Int32) {
        title = TaskManagerStrings.killTitle
        body = TaskManagerStrings.killBody(name: name, pid: pid)
        button = TaskManagerStrings.killButton
    }
}
