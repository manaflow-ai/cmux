import Foundation

public nonisolated enum TasksSourceEvent: Sendable {
    case connection(TasksConnection)
    case snapshot(TasksSnapshot)
    case event(TasksEvent)
    /// The owner's answer to an intent (`ok` or a reject message).
    case settled(key: String, reject: String?)
}

/// Where the model gets owner data. The App supplies the socket source to
/// the local Tasks owner; demos and tests use `MockTasksSource`.
@MainActor
public protocol TasksSource: AnyObject {
    func start(_ sink: @escaping @MainActor (TasksSourceEvent) -> Void)
    func send(_ intent: TasksIntent)
    func stop()
}
