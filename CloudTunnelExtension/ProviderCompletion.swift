/// Carries a NetworkExtension completion handler into a task.
final class ProviderCompletion: @unchecked Sendable {
    // Safe: Apple's handler is not annotated Sendable but may be called from any thread; it is
    // immutable here and the provider calls it exactly once.
    private let completion: ((any Error)?) -> Void

    init(_ completion: @escaping ((any Error)?) -> Void) { self.completion = completion }

    func callAsFunction(_ error: (any Error)?) { completion(error) }
}
