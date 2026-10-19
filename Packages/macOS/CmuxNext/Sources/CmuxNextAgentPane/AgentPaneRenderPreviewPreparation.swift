import Foundation

/// Releases the caller on cancellation even when WebKit never answers its preparation callback.
@MainActor
final class AgentPaneRenderPreviewPreparation {
    private let evaluate: (@escaping @MainActor (Result<Any, any Error>) -> Void) -> Void
    struct Document: Sendable {
        let html: String
        let width: Int
        let dark: Bool
    }

    private var continuation: CheckedContinuation<Document, any Error>?

    init(evaluate: @escaping (@escaping @MainActor (Result<Any, any Error>) -> Void) -> Void) {
        self.evaluate = evaluate
    }

    func run() async throws -> Document {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                evaluate { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Any, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result.flatMap { raw in
            if let prepared = raw as? [String: Any], let code = prepared["error"] as? String {
                return .failure(AgentPaneRenderPreviewError(rawValue: code) ?? .failed)
            }
            guard let prepared = raw as? [String: Any], let html = prepared["document"] as? String,
                  let width = prepared["width"] as? Int, (1...1440).contains(width) else {
                return .failure(AgentPaneRenderPreviewError.notLaidOut)
            }
            return .success(Document(html: html, width: width, dark: prepared["theme"] as? String == "dark"))
        })
    }
}
