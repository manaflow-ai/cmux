public import Foundation
import Observation

/// One question in a panel's permission prompt bar.
public struct BrowserPermissionPrompt: Identifiable, Equatable, Sendable {
    /// The buttons a prompt offers.
    public enum Style: Equatable, Sendable {
        /// Camera and microphone: Never allow · Allow this time · Allow while visiting the site.
        case captureDevices
        /// Every other kind: Block · Allow.
        case blockOrAllow
    }

    public let id: UUID
    /// The kinds asked about together, in display order.
    public let kinds: [BrowserPagePermissionRequest.Kind]
    /// The requesting origin.
    public let origin: URL

    public init(id: UUID = UUID(), kinds: [BrowserPagePermissionRequest.Kind], origin: URL) {
        self.id = id
        self.kinds = kinds
        self.origin = origin
    }

    /// The prompt's buttons: capture devices get Chrome's three answers.
    public var style: Style {
        kinds.allSatisfy { $0 == .camera || $0 == .microphone } ? .captureDevices : .blockOrAllow
    }

    /// The origin as shown in the bar: host and non-default port, no scheme.
    public var displayOrigin: String {
        guard let host = origin.host, !host.isEmpty else { return origin.absoluteString }
        if let port = origin.port, port != (origin.scheme?.lowercased() == "https" ? 443 : 80) {
            return "\(host):\(port)"
        }
        return host
    }
}

/// The person's answer in the prompt bar.
public enum BrowserPermissionPromptAnswer: Equatable, Sendable {
    /// "Allow while visiting the site" or "Allow": granted and remembered.
    case allowAndRemember
    /// "Allow this time": granted, not remembered.
    case allowOnce
    /// "Never allow" or "Block": denied and remembered.
    case block
}

/// A panel's permission questions, shown one at a time in the prompt bar.
/// Later requests wait their turn; navigating away ends every question
/// without an answer.
@MainActor
@Observable
public final class BrowserPermissionPromptQueue {
    /// Every waiting question, the shown one first.
    public private(set) var prompts: [BrowserPermissionPrompt] = []
    /// The question the bar shows, or `nil` when the bar is hidden.
    public var current: BrowserPermissionPrompt? { prompts.first }

    @ObservationIgnored private var completions: [UUID: (BrowserPermissionPromptAnswer?) -> Void] = [:]

    public init() {}

    /// Adds a question.
    /// - Parameters:
    ///   - prompt: The question.
    ///   - completion: Called once with the answer, or `nil` when the question ended unanswered.
    public func enqueue(_ prompt: BrowserPermissionPrompt, completion: @escaping (BrowserPermissionPromptAnswer?) -> Void) {
        guard completions[prompt.id] == nil else { return }
        completions[prompt.id] = completion
        prompts.append(prompt)
    }

    /// Answers a question (normally the shown one).
    /// - Returns: Whether the question was waiting.
    @discardableResult
    public func answer(_ id: UUID, with answer: BrowserPermissionPromptAnswer) -> Bool {
        finish(id, answer)
    }

    /// Ends one question without an answer (its request went away).
    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        finish(id, nil)
    }

    /// Ends every question without an answer (navigation, panel closed).
    public func cancelAll() {
        let ended = prompts.compactMap { completions[$0.id] }
        guard !ended.isEmpty else { return }
        prompts.removeAll()
        completions.removeAll()
        for completion in ended {
            completion(nil)
        }
    }

    private func finish(_ id: UUID, _ answer: BrowserPermissionPromptAnswer?) -> Bool {
        guard let completion = completions.removeValue(forKey: id) else { return false }
        prompts.removeAll { $0.id == id }
        completion(answer)
        return true
    }
}
