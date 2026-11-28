public import CmuxNextCloud
import Foundation

extension SessionConsentResponder {
    /// Shows one consent question (title, lines, allow, deny) and answers whether the person chose allow; the
    /// app passes `CmuxDialogCenter.askConsent`, whose allow takes only the person's own click.
    public typealias Dialog = @Sendable (_ title: String, _ lines: [String], _ allow: String, _ deny: String) async -> Bool

    /// The responder a cmux NIGHTLY on the production account sets on its control socket
    /// (`auth.session.request`); nil for every other build, whose socket then does not know the method.
    /// NIGHTLY's account and backend come from `auth`; "Sign In" calls the web route with NIGHTLY's own tokens.
    @MainActor
    public static func forNightly(launch: LaunchIdentity, auth: CloudAuth, dialog: @escaping Dialog) -> SessionConsentResponder? {
        let configuration = auth.configuration
        guard launch.bundleID == SessionConsentClient.nightlyBundleID, configuration.isProductionAuth else { return nil }
        return SessionConsentResponder(
            nightly: { @MainActor in
                await auth.awaitRestored()
                return Nightly(stackProjectID: configuration.stackProjectID, apiOrigin: configuration.apiBaseURL.absoluteString,
                               authWebOrigin: configuration.authWebOrigin.absoluteString, signedIn: auth.isSignedIn,
                               accountEmail: auth.user?.primaryEmail)
            },
            consent: { ask in
                // main-actor-ok: one consent ask's message, a few lines, on a sign-in request.
                await dialog(ask.title, ask.message.split(separator: "\n").map(String.init), ask.allow, ask.deny)
            },
            mint: { call in await mintSession(call, auth: auth) })
    }

    /// The web route call with NIGHTLY's current tokens (`Authorization: Bearer`, `X-Stack-Refresh-Token`);
    /// `(0, empty)` when NIGHTLY has no tokens or the call failed. Nothing here logs a token or the answer.
    static func mintSession(_ call: SessionConsentMintCall, auth: CloudAuth) async -> (status: Int, body: Data) {
        guard let tokens = try? await auth.tokens() else { return (0, Data()) }
        var request = URLRequest(url: call.url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(tokens.access)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refresh, forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.httpBody = call.body
        guard let (body, response) = try? await URLSession.cloudNoStore.data(for: request) else { return (0, Data()) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }
}

extension SessionConsentClient {
    /// What a signed-out build asks NIGHTLY with (`CloudAuth.ConsentSession`, `auth.session.request`): its bundle
    /// id, tag, Stack project and API origin, waiting the time Rust gives (150 s, the person's answer included).
    public static func consentSession(_ configuration: CloudConfiguration,
                                      tag: String? = LaunchIdentity.current().tag) -> CloudAuth.ConsentSession {
        { timeout in
            await SessionConsentClient(socketPath: nightlySocketPath(), timeout: timeout)
                .requestTokens(bundleID: configuration.bundleID ?? "", tag: tag, stackProjectID: configuration.stackProjectID,
                               apiOrigin: configuration.apiBaseURL.absoluteString)
        }
    }
}
