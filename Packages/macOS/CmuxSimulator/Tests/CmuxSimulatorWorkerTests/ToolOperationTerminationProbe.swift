@MainActor
final class ToolOperationTerminationProbe {
    private(set) var count = 0

    func terminate() { count += 1 }
}
