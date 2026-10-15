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
        /// macOS has turned the device off for cmux: Not now · Open System Settings (spec §4 v1.4).
        case systemBlocked
        /// The device is managed by the organization: Not now only.
        case systemManaged
    }

    /// What the strip says.
    public enum Variant: Equatable, Sendable {
        /// The site's question.
        case ask
        /// cmux lacks macOS's permission for the devices (the page was already denied).
        case systemBlocked
        /// The devices are managed on this Mac (the page was already denied).
        case systemManaged
    }

    public let id: UUID
    /// The kinds asked about together, in display order.
    public let kinds: [BrowserPagePermissionRequest.Kind]
    /// The requesting origin.
    public let origin: URL
    /// The top-level page's origin when an embedded frame of another site
    /// asks (the prompt names both sites); `nil` when the page itself asks.
    public let embeddingOrigin: URL?
    /// What the strip says.
    public let variant: Variant

    public init(
        id: UUID = UUID(),
        kinds: [BrowserPagePermissionRequest.Kind],
        origin: URL,
        topLevelURL: URL? = nil,
        variant: Variant = .ask
    ) {
        self.id = id
        self.kinds = kinds
        self.origin = origin
        self.variant = variant
        let key = BrowserSitePermissionStore.originKey(for: origin)
        if let topLevelURL, let topKey = BrowserSitePermissionStore.originKey(for: topLevelURL), topKey != key {
            embeddingOrigin = topLevelURL
        } else {
            embeddingOrigin = nil
        }
    }

    /// The prompt's buttons: capture devices get Chrome's three answers.
    public var style: Style {
        switch variant {
        case .systemBlocked: return .systemBlocked
        case .systemManaged: return .systemManaged
        case .ask: return kinds.allSatisfy { $0 == .camera || $0 == .microphone } ? .captureDevices : .blockOrAllow
        }
    }

    /// What "Allow" means in the ``Style/blockOrAllow`` bar: remembered for
    /// the site, except clipboard read, which WebKit asks about on every read
    /// (its Paste callout), so a Chromium tab never grants it for good.
    public var allowAnswer: BrowserPermissionPromptAnswer {
        kinds == [.clipboardRead] ? .allowOnce : .allowAndRemember
    }

    /// Whether `other` asks the same origin about the same kinds.
    func asksSameQuestion(as other: BrowserPermissionPrompt) -> Bool {
        variant == other.variant
            && Set(kinds) == Set(other.kinds)
            && Self.key(origin) == Self.key(other.origin)
            && embeddingOrigin.map(Self.key) == other.embeddingOrigin.map(Self.key)
    }

    private static func key(_ url: URL) -> String {
        BrowserSitePermissionStore.originKey(for: url) ?? url.absoluteString
    }

    /// The embedding page's origin as shown in the bar, or `nil`.
    public var displayEmbeddingOrigin: String? {
        embeddingOrigin.map(Self.display)
    }

    /// The origin as shown in the bar: host and non-default port, no scheme.
    public var displayOrigin: String {
        Self.display(origin)
    }

    private static func display(_ url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        if let port = url.port, port != (url.scheme?.lowercased() == "https" ? 443 : 80) {
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
    /// "Open System Settings" (system-blocked strip).
    case openSystemSettings
    /// "Not now" (system-blocked or managed strip).
    case notNow
}

/// A panel's permission questions, shown one at a time in the prompt bar.
/// Later requests wait their turn, and a request asking the same origin about
/// the same kinds as a waiting one shares its answer (one question, not two).
/// Navigating away or closing the panel must call ``cancelAll()``, which
/// ends every question without an answer.
@MainActor
@Observable
public final class BrowserPermissionPromptQueue {
    /// Every waiting question, the shown one first.
    public private(set) var prompts: [BrowserPermissionPrompt] = []
    /// The question the bar shows, or `nil` when the bar is hidden.
    public var current: BrowserPermissionPrompt? { prompts.first }

    @ObservationIgnored private var completions: [UUID: [(BrowserPermissionPromptAnswer?) -> Void]] = [:]

    public init() {}

    /// Adds a question.
    /// - Parameters:
    ///   - prompt: The question.
    ///   - completion: Called once with the answer, or `nil` when the question ended unanswered.
    public func enqueue(_ prompt: BrowserPermissionPrompt, completion: @escaping (BrowserPermissionPromptAnswer?) -> Void) {
        // A reused id is a caller bug: end the new question at once rather than lose it.
        guard completions[prompt.id] == nil else { return completion(nil) }
        if let same = prompts.first(where: { $0.asksSameQuestion(as: prompt) }) {
            completions[same.id, default: []].append(completion)
            return
        }
        completions[prompt.id] = [completion]
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
        let ended = prompts.flatMap { completions[$0.id] ?? [] }
        guard !ended.isEmpty else { return }
        prompts.removeAll()
        completions.removeAll()
        for completion in ended {
            completion(nil)
        }
    }

    private func finish(_ id: UUID, _ answer: BrowserPermissionPromptAnswer?) -> Bool {
        guard let ended = completions.removeValue(forKey: id) else { return false }
        prompts.removeAll { $0.id == id }
        for completion in ended {
            completion(answer)
        }
        return true
    }
}
