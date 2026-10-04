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
    /// and its current domain policy (`nil`: none).
    public func isGranted(by granted: Set<String>, policy: BrowserReplDomainPolicy?) -> Bool {
        !permissions.isEmpty && permissions.allSatisfy(granted.contains)
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
