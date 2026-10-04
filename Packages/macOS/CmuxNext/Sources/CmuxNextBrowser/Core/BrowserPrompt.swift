public import Foundation

/// A pending question from a page: a permission request or a JavaScript
/// dialog. The chrome shows the first pending prompt of the selected tab.
/// A prompt is answered exactly once; closing the tab denies every pending one.
public final class BrowserPrompt: Identifiable {
    public let id = UUID()
    public let kind: BrowserPromptKind
    /// Origin shown to the user ("https://meet.example.com").
    public let origin: String
    private var completion: ((BrowserPromptResponse) -> Void)?

    public init(kind: BrowserPromptKind, origin: String, completion: @escaping (BrowserPromptResponse) -> Void) {
        self.kind = kind
        self.origin = origin
        self.completion = completion
    }

    public var isResolved: Bool { completion == nil }

    /// Answers the prompt. Later calls are ignored.
    public func respond(_ response: BrowserPromptResponse) {
        guard let completion else { return }
        self.completion = nil
        completion(response)
    }

    /// The response used when the prompt is dismissed without an answer.
    public var dismissalResponse: BrowserPromptResponse {
        switch kind {
        case .permission: .deny
        case .alert: .accept
        case .confirm, .textInput, .credentials: .cancel
        }
    }
}

// MARK: - Downloads
