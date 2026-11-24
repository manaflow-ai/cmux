import Foundation

/// Whether an agent's or a script's capture of this app's windows is raw (nothing masked).
///
/// The person's own app always masks browser, chat, Home and other private areas for automation
/// (``ScreenshotMask``). A side copy (`scripts/cmux-next/side-instance.sh`, `cmux app try`) is a
/// separate bundle with its own state dir and a mock keychain, so it holds only test chats; its
/// captures are raw so agent-chat UI can be recorded there. Decided 2026-11-22: "keep masking in
/// the person's own app, and unmask chats/Home/browser in a side copy ... Gate it on the instance
/// being a side copy with its own state dir (not a flag a script can flip on the real app)".
///
/// The rule reads the app's own signed bundle (its id and Info.plist `LSEnvironment`), never the
/// process environment or settings, so nothing a script sets at run time turns it on. A side copy
/// signed in to Cloud (`--keep-sign-in`) may show the person's own chats, so it masks again.
public struct SideCopyCapture {
    public init() {}
    /// The `unmasked` value a raw capture reports.
    public static let reason = "side-copy"

    /// Whether this process is a side copy, from its Info.plist.
    public static let isSideCopy: Bool = isSideCopy(bundleID: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary)

    /// The rule on its own, for tests.
    public static func isSideCopy(bundleID: String?, info: [String: Any]?) -> Bool {
        guard let bundleID, bundleID.contains(".side-") else { return false }
        let environment = info?["LSEnvironment"] as? [String: Any]
        return environment?["CMUX_MOCK_KEYCHAIN"] as? String == "1" && environment?["CMUX_NEXT_CONFIG_FILE"] is String
    }

    /// Why a script's capture is raw now (``reason``), or nil when it masks: a side copy that is
    /// not signed in to Cloud.
    public static func unmasked(signedIn: Bool) -> String? {
        isSideCopy && !signedIn ? reason : nil
    }
}
