import Foundation
import Testing

@testable import CmuxBrowser

/// A tab a session created answers camera, microphone, geolocation and
/// notification requests from the session's grants. A frame the session's
/// domain policy blocks (one loaded before the policy tightened, or while its
/// content rules were replaced) must not get them.
@Suite("Browser REPL permission requests")
struct BrowserReplPermissionRequestTests {
    private func policy(allowed: [String]? = nil, prohibited: [String] = []) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        return policy
    }

    private func document(_ origin: String) -> BrowserReplFrameDocument {
        BrowserReplFrameDocument(origin: origin, place: origin)
    }

    @Test("A granted permission goes to an origin the policy allows, and only granted ones do")
    func grantsFollowTheSessionsPermissions() throws {
        let allowed = try policy(allowed: ["example.com"])
        let request = BrowserReplPermissionRequest(permissions: ["camera"], origin: document("https://example.com"), frame: document("https://example.com"))
        #expect(request.isGranted(by: ["camera"], policy: allowed))
        #expect(request.isGranted(by: ["camera"], policy: nil))
        #expect(!request.isGranted(by: ["microphone"], policy: allowed))
        let both = BrowserReplPermissionRequest(permissions: ["camera", "microphone"], origin: document("https://example.com"))
        #expect(!both.isGranted(by: ["camera"], policy: allowed))
        #expect(both.isGranted(by: ["camera", "microphone"], policy: allowed))
    }

    @Test("A frame or origin the creating session's policy blocks is denied, though the permission is granted",
          arguments: ["camera", "microphone", "geolocation", "notifications"])
    func aBlockedRequesterIsDenied(_ permission: String) throws {
        let allowedOnly = try policy(allowed: ["example.com"])
        let prohibiting = try policy(prohibited: ["evil.test"])
        let granted: Set<String> = [permission]
        // An embedded frame from a blocked origin asks.
        let fromBlockedFrame = BrowserReplPermissionRequest(permissions: [permission], origin: document("https://evil.test"), frame: document("https://evil.test"))
        #expect(!fromBlockedFrame.isGranted(by: granted, policy: allowedOnly))
        #expect(!fromBlockedFrame.isGranted(by: granted, policy: prohibiting))
        // WebKit names the requesting origin only (notifications).
        let originOnly = BrowserReplPermissionRequest(permissions: [permission], origin: document("https://evil.test"))
        #expect(!originOnly.isGranted(by: granted, policy: prohibiting))
        // The frame shows a blocked page under an allowed origin's name, or
        // the other way round: either refuses.
        let mixed = BrowserReplPermissionRequest(permissions: [permission], origin: document("https://example.com"), frame: document("https://evil.test"))
        #expect(!mixed.isGranted(by: granted, policy: prohibiting))
        // An opaque origin cannot be judged under a policy.
        let opaque = BrowserReplPermissionRequest(permissions: [permission], origin: BrowserReplFrameDocument(origin: "null", place: "about://"))
        #expect(!opaque.isGranted(by: granted, policy: allowedOnly))
        #expect(opaque.isGranted(by: granted, policy: nil))
    }
}
