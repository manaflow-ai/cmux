public import WebKit

/// A camera, microphone, geolocation or notification request in a tab a
/// REPL session created, which the session answers from the permissions it
/// granted (`session.configure({ permissions })`) instead of a prompt
/// nobody can answer.
public struct BrowserReplPermissionRequest: Sendable, Equatable {
    /// The permissions the request needs (`camera`, `microphone`,
    /// `geolocation`, `notifications`); all must be granted.
    public var permissions: [String]
    /// The origin that asks, as WebKit names it.
    public var origin: BrowserReplFrameDocument?
    /// The frame that asks, as WebKit recorded it, when WebKit names one.
    public var frame: BrowserReplFrameDocument?

    public init(permissions: [String], origin: BrowserReplFrameDocument?, frame: BrowserReplFrameDocument? = nil) {
        self.permissions = permissions
        self.origin = origin
        self.frame = frame
    }

    /// Whether the request is granted, given the creating session's grants
    /// and its current domain policy (`nil`: none). Under a policy the origin
    /// that asks and the frame's document must both be allowed: a frame the
    /// policy blocks can still be in the tab (loaded before the policy
    /// tightened, or while its content rules were replaced), and a grant
    /// must not hand it the camera, microphone, location or notifications.
    /// An origin the policy cannot judge (opaque, or not named) is denied.
    public func isGranted(by granted: Set<String>, policy: BrowserReplDomainPolicy?) -> Bool {
        isGranted(by: granted, authority: BrowserReplDocumentAuthority(sessionID: "", policy: policy ?? BrowserReplDomainPolicy()), in: nil)
    }

    /// Whether the request is granted, given the creating session's grants
    /// and its authority on the documents that ask in `tab`
    /// (``isAllowed(by:in:)``).
    public func isGranted(by granted: Set<String>, authority: BrowserReplDocumentAuthority, in tab: BrowserReplTabFacts?) -> Bool {
        guard !permissions.isEmpty, permissions.allSatisfy(granted.contains) else { return false }
        return isAllowed(by: authority, in: tab)
    }

    /// Whether `authority` allows the origin that asks and the frame's
    /// document in `tab` (``BrowserReplDocumentAuthority/verdict(_:)``). An
    /// origin it cannot judge (opaque, or not named) is refused while the
    /// authority judges anything in the tab.
    public func isAllowed(by authority: BrowserReplDocumentAuthority, in tab: BrowserReplTabFacts?) -> Bool {
        guard authority.isActive(in: tab) else { return true }
        guard let origin, let name = origin.origin, name != "null" else { return false }
        if authority.verdict(BrowserReplAccess(.document(origin), in: tab)) != .allowed { return false }
        if let frame, authority.verdict(BrowserReplAccess(.document(frame), in: tab)) != .allowed { return false }
        return true
    }
}

extension BrowserReplFrameDocument {
    /// The document of a requesting security origin (a permission request):
    /// its origin, which is also where it is.
    @MainActor
    public init(securityOrigin: WKSecurityOrigin) {
        let origin = Self.origin(of: securityOrigin)
        self.init(origin: origin, place: origin == "null" ? "about://" : origin)
    }
}
