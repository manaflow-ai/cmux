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
        // Closing the tab refuses the waiting downloads and remembers nothing.
        case .permission(.automaticDownloads): .cancel
        case .permission: .deny
        case .alert: .accept
        case .confirm, .textInput, .credentials: .cancel
        }
    }
}

// MARK: - Downloads

extension BrowserPrompt {
    /// An answer to a permission question without the mouse
    /// (`browser.prompt.allow` / `browser.prompt.block`).
    public enum PermissionChoice: Sendable {
        /// Allow, remembered for the site.
        case allow
        /// Block (Never allow), remembered for the site.
        case block
    }

    /// Answers the first of `prompts` (the one the prompt bar shows) when it
    /// is a permission question. False when it is not, or none is pending.
    @discardableResult
    public static func answerFirstPermission(_ choice: PermissionChoice, in prompts: [BrowserPrompt]) -> Bool {
        guard let prompt = firstPermission(in: prompts) else { return false }
        prompt.respond(choice == .allow ? .allow : .deny)
        return true
    }

    /// The first of `prompts` when it is an open permission question.
    public static func firstPermission(in prompts: [BrowserPrompt]) -> BrowserPrompt? {
        guard let first = prompts.first, !first.isResolved, case .permission = first.kind else { return nil }
        return first
    }
}
