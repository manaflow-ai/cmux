/// How cmux answers a Chromium permission request in a Chromium-engine tab.
///
/// Chromium's own permission bubble anchors to a toolbar cmux never shows, so
/// a request cmux leaves to Chromium would wait until it times out. Every
/// request is therefore answered here: at once (``Decision/accept`` or
/// ``Decision/deny``) or by asking the person in cmux's own prompt
/// (``Decision/prompt(_:)``).
///
/// The defaults match what a WebKit tab in cmux does today, so switching a
/// tab's engine never widens what a page may do:
/// - camera and microphone ask the person (WebKit shows its capture prompt);
/// - clipboard read asks the person (WebKit shows its Paste callout per read);
/// - location, notifications and every other kind are denied (WebKit tabs
///   deny geolocation and have no web notifications).
/// A tab a REPL/automation session created answers from the session's
/// grants instead, exactly like its WebKit tabs. Changing these defaults is a
/// trust decision (cmux issue 13742).
public struct BrowserChromiumPermissionPolicy: Sendable {
    /// A kind cmux can ask the person about.
    public enum PromptKind: String, CaseIterable, Hashable, Sendable {
        case camera
        case microphone
        case clipboardRead
    }

    /// The answer to one request.
    public enum Decision: Equatable, Sendable {
        /// Accept without asking.
        case accept
        /// Deny without asking.
        case deny
        /// Ask the person about these kinds (in this order) in one prompt.
        case prompt([PromptKind])
    }

    /// What the shim sends back for a request (`cmux_shim_permission_continue`).
    /// There is no "dismiss": Chromium counts dismissals toward blocking a
    /// site for days (embargo), so an unanswered prompt is ``noAnswer``.
    public enum ShimResult: Int32, Sendable {
        /// The request ends unanswered when its page goes away.
        case noAnswer = 0
        case accept = 1
        case deny = 2
    }

    /// The kinds that ask the person, by request bit.
    public static let defaultPromptKinds: [(BrowserChromiumPermissionRequest, PromptKind)] = [
        (.camera, .camera),
        (.microphone, .microphone),
        (.clipboard, .clipboardRead),
    ]

    /// Session grant names (`session.configure` `permissions`) by request bit.
    public static let sessionGrantNames: [(BrowserChromiumPermissionRequest, String)] = [
        (.camera, "camera"),
        (.microphone, "microphone"),
        (.geolocation, "geolocation"),
        (.notifications, "notifications"),
    ]

    public init() {}

    /// Decides one request.
    /// - Parameters:
    ///   - request: The requested kinds.
    ///   - sessionGrants: The creating session's granted permission names when
    ///     the tab follows a session's policies, else `nil`.
    /// - Returns: The decision; any kind cmux cannot ask about denies the whole request.
    public func decide(_ request: BrowserChromiumPermissionRequest, sessionGrants: Set<String>?) -> Decision {
        guard !request.isEmpty else { return .deny }
        if let sessionGrants {
            var remaining = request
            for (bit, name) in Self.sessionGrantNames where request.contains(bit) {
                guard sessionGrants.contains(name) else { return .deny }
                remaining.remove(bit)
            }
            return remaining.isEmpty ? .accept : .deny
        }
        var remaining = request
        var kinds: [PromptKind] = []
        for (bit, kind) in Self.defaultPromptKinds where request.contains(bit) {
            kinds.append(kind)
            remaining.remove(bit)
        }
        guard remaining.isEmpty, !kinds.isEmpty else { return .deny }
        return .prompt(kinds)
    }

    /// The shim answer for a decision taken without the person.
    /// - Returns: `nil` for ``Decision/prompt(_:)``, which waits for the person.
    public static func immediateShimResult(for decision: Decision) -> ShimResult? {
        switch decision {
        case .accept: .accept
        case .deny: .deny
        case .prompt: nil
        }
    }

    /// The shim answer once the person answered the prompt.
    /// - Parameter allowed: `true` for Allow, `false` for Don't Allow, `nil`
    ///   when the prompt closed without an answer (tab closed, navigated away).
    public static func shimResult(forPromptAnswer allowed: Bool?) -> ShimResult {
        switch allowed {
        case true?: .accept
        case false?: .deny
        case nil: .noAnswer
        }
    }
}
