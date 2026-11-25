import Foundation

/// What a `browser.page.*` call does to its page, as the engine sees it while the call runs
/// (``current``): an agent that only reads a page (``reads``) leaves the page's passkeys to the person.
///
/// Chrome refuses WebAuthn only while its own agent is in control of a tab (`IsActorActingOnWebContents`);
/// once the agent hands the tab to the person, the person's sign-in runs. In cmux every agent call refused
/// again, the reads too, so the Chief's watch of a sign-in (`cmux browser right state` or `snapshot` every
/// 5 s, chief-auth-escalation step 6) took the page back from the person: a passkey request the page
/// starts on its own after their click (Google's challenge page after "Try again", a fetch before the
/// `get`) got NotAllowedError before any sheet. Reads run no agent script that could start a ceremony.
public enum BrowserPageIntent: Sendable, Hashable {
    /// The call can start a ceremony: input, navigation, an agent's own script.
    case acts
    /// The call only reads: state, snapshot, text, value, screenshot, tabs, a wait without a script.
    case reads

    /// The intent of the `browser.page.*` call running in this task; ``acts`` outside one.
    @TaskLocal public static var current: BrowserPageIntent = .acts

    /// The methods that only read their page or the profile: their scripts are cmux's own. `browser.page.eval`, a
    /// wait with the agent's own `function` and every input verb can call `navigator.credentials` themselves.
    static let readMethods: Set<String> = [
        "browser.page.state", "browser.page.snapshot", "browser.page.screenshot", "browser.page.tabs",
        "browser.page.text", "browser.page.value", "browser.page.wait", "browser.page.passkey_status",
        "browser.page.cookies.get", "browser.page.storage.get", "browser.page.downloads", "browser.page.download.wait",
    ]

    /// The intent of `call`: ``reads`` for the read verbs, ``acts`` for every other.
    static func of(_ call: ControlCall) -> BrowserPageIntent {
        guard readMethods.contains(call.request.method) else { return .acts }
        if call.request.method == "browser.page.wait", let script = call.request.params["function"]?.stringValue, !script.isEmpty {
            return .acts
        }
        return .reads
    }
}
