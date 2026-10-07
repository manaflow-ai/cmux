import CmuxMobileWire

/// Where a dispatched task runs (`task.dispatch:result`).
public struct MobileTaskDispatchResult: Hashable, Sendable {
    public var task: String
    public var workspace: String
    public var tab: String

    public init(task: String, workspace: String, tab: String) {
        self.task = task
        self.workspace = workspace
        self.tab = tab
    }

    var jsonValue: JSONValue {
        .object(["task": .string(task), "workspace": .string(workspace), "tab": .string(tab)])
    }
}
