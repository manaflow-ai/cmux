import Foundation

/// An https GET through a tab's own Chromium request context: the profile's cookies go with it
/// inside Chromium's network stack and never reach Swift or a page (email verification AutoFill
/// reads Gmail's inbox feed with it, plans/cmux-next/email-verification-autofill/DESIGN.md).
/// Main thread (the CEF UI thread).
extension CEFRuntime {
    /// The status and body of `url` as tab `browser`'s profile fetches it; nil when this shim has
    /// no profile fetch, the browser is gone, or the fetch failed (also a body over `maxBytes`).
    func profileFetch(_ browser: Int32, url: URL, maxBytes: Int) async -> (status: Int, body: Data)? {
        guard shim?.profileFetch != nil else { return nil }
        let reply = try? await siteCall(browser, what: "profile fetch") { shim, id in
            shim.profileFetch?(browser, id, url.absoluteString, Int32(clamping: maxBytes)) ?? 0
        }
        guard let reply, reply.value > 0 else { return nil }
        return (Int(reply.value), Data(base64Encoded: reply.json) ?? Data())
    }
}
