import Foundation

/// Calls a context menu's completion at most once: the engine expects exactly one answer per
/// menu (a chosen row or a dismissal).
@MainActor
final class BrowserContextMenuCompletion {
    private var completion: ((Int?) -> Void)?

    init(_ completion: @escaping (Int?) -> Void) {
        self.completion = completion
    }

    /// Answers with `id` unless already answered.
    /// - Parameter id: The chosen engine row's id, or `nil`.
    func finish(_ id: Int?) {
        guard let completion else { return }
        self.completion = nil
        completion(id)
    }
}
