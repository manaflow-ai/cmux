import Foundation

/// How a browser panel answers a page's permission request when the page's
/// engine has no prompt of its own cmux can show (the Chromium engine:
/// Chromium's permission bubble anchors to a toolbar cmux never shows, so a
/// request left to Chromium would wait until it times out).
///
/// The defaults preserve WebKit's decisions for existing tabs. Chromium's
/// native notification API is disabled and its fallback settles denied, just
/// as WebKit's delegate denies web notifications immediately:
/// - camera and microphone ask the person (WebKit shows its capture prompt);
/// - clipboard read asks the person (WebKit shows its Paste callout per read);
/// - location, notifications, screen capture and every other kind are denied
///   without asking (WebKit tabs deny geolocation and web notifications).
///
/// A tab a REPL/automation session created answers from the session's grants
/// instead, exactly like its WebKit tabs (`session.configure` `permissions`).
/// Chromium's Notification API fallback follows this denial policy; WebKit's
/// existing delegate decision remains unchanged.
public struct BrowserPagePermissionPolicy: Sendable {
    /// The policy's answer to one request.
    public enum Outcome: Equatable, Sendable {
        /// Grant without asking.
        case grant
        /// Deny without asking.
        case deny
        /// Ask the person about these kinds, in this order, in one prompt.
        case ask([BrowserPagePermissionRequest.Kind])
    }

    /// Kinds cmux asks the person about.
    public let askableKinds: Set<BrowserPagePermissionRequest.Kind>

    /// Session grant names by kind; a session can grant only these.
    public static let sessionGrantNames: [BrowserPagePermissionRequest.Kind: String] = [
        .camera: "camera",
        .microphone: "microphone",
        .geolocation: "geolocation",
        .notifications: "notifications",
    ]

    /// The shipping defaults (see the type documentation).
    public static let defaultAskableKinds: Set<BrowserPagePermissionRequest.Kind> = [.camera, .microphone, .clipboardRead]

    /// Creates a policy.
    /// - Parameter askableKinds: Kinds cmux asks the person about; every other kind is denied.
    public init(askableKinds: Set<BrowserPagePermissionRequest.Kind> = Self.defaultAskableKinds) {
        self.askableKinds = askableKinds
    }

    /// Decides one request.
    /// - Parameters:
    ///   - request: The page's request.
    ///   - sessionGrants: The creating session's granted permission names when
    ///     the tab follows a session's policies, else `nil`.
    /// - Returns: The outcome; a kind cmux cannot ask about denies the whole request.
    public func decide(_ request: BrowserPagePermissionRequest, sessionGrants: Set<String>?) -> Outcome {
        var kinds: [BrowserPagePermissionRequest.Kind] = []
        for kind in request.kinds where !kinds.contains(kind) {
            kinds.append(kind)
        }
        guard !kinds.isEmpty else { return .deny }
        if let sessionGrants {
            let granted = kinds.allSatisfy { kind in
                Self.sessionGrantNames[kind].map { sessionGrants.contains($0) } ?? false
            }
            return granted ? .grant : .deny
        }
        guard kinds.allSatisfy({ askableKinds.contains($0) }) else { return .deny }
        // A permission request needs an origin to show and to remember.
        guard request.origin?.host?.isEmpty == false else { return .deny }
        return .ask(kinds)
    }
}
