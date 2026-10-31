import Foundation

/// Developer toggles for DEBUG and Demo builds, set in Settings → Developer
/// and read at launch, so a demo on a phone needs no launch arguments.
/// Non-DEBUG builds (Release, Production) never read them, and Production
/// removes any stored value at launch (``removeStoredValues(from:)``).
public enum DeveloperOptions {
    /// `UserDefaults` key: sign in as the local mock user with sample data.
    public static let mockDataKey = "cmuxMobile.dev.mockData"
    /// `UserDefaults` key: a scripted demo to run once at the next launch.
    public static let launchDemoKey = "cmuxMobile.dev.launchDemo"
    /// `UserDefaults` key: relay only, to simulate a distant network. Links
    /// skip every direct path (WebRTC and WireGuard over TURN).
    /// Applies live: changing it redials.
    public static let relayOnlyKey = "cmuxMobile.dev.relayOnly"
    /// `UserDefaults` key: block UDP, to simulate a network that passes only
    /// TCP: WireGuard sends no plain UDP and rides TURN over TLS on 443.
    /// Applies live: changing it redials.
    public static let blockUDPKey = "cmuxMobile.dev.blockUDP"
    /// `UserDefaults` key: streamed browser tabs keep their video on the
    /// reliable `browser` channel even over WebRTC (no media lane), the
    /// baseline of verify/browser-video-track.md. Applies at the next dial.
    public static let browserVideoOnChannelKey = "cmuxMobile.dev.browserVideoOnChannel"
    /// `UserDefaults` key: mock approvals wait 2 s for "Face ID" so the waiting state
    /// can be seen and captured (`-cmuxMobile.dev.slowFaceID YES`). DEBUG mock content only.
    public static let slowFaceIDKey = "cmuxMobile.dev.slowFaceID"
    /// `UserDefaults` key: the terminal demo's phases (`-CmuxMobileTerminalDemoPhases`).
    public static let terminalDemoPhasesKey = "CmuxMobileTerminalDemoPhases"

    /// Every stored developer setting. A build without the Developer page
    /// removes them so a value set by an earlier Debug or Demo install in the
    /// same container can never apply.
    public static let storedKeys = [
        mockDataKey, launchDemoKey, relayOnlyKey, blockUDPKey, browserVideoOnChannelKey, terminalDemoPhasesKey,
        slowFaceIDKey,
    ]

    /// Removes every stored developer setting (Production launch).
    public static func removeStoredValues(from defaults: UserDefaults = .standard) {
        for key in storedKeys { defaults.removeObject(forKey: key) }
    }

    /// Whether mock sign-in with sample data is on (takes effect at launch).
    /// Always off in non-DEBUG builds, whatever is stored.
    public static var mockData: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: mockDataKey)
        #else
        false
        #endif
    }

    /// How long a mock approval waits for "Face ID" (2 s with the developer switch).
    /// Always zero outside DEBUG builds.
    public static var mockFaceIDDelay: Duration {
        #if DEBUG
        UserDefaults.standard.bool(forKey: slowFaceIDKey) ? .seconds(2) : .zero
        #else
        .zero
        #endif
    }

    /// Whether relay-only links are on. Always off in Release builds.
    public static var relayOnly: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: relayOnlyKey)
        #else
        false
        #endif
    }

    /// Whether WireGuard acts as on a network that blocks UDP. Always off in
    /// Release builds.
    public static var blockUDP: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: blockUDPKey)
        #else
        false
        #endif
    }

    /// Whether browser video stays on its channel (no WebRTC video track).
    /// Always off in Release builds.
    public static var browserVideoOnChannel: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: browserVideoOnChannelKey)
        #else
        false
        #endif
    }

    #if DEBUG
    /// Mock content (sample Feed, mock agent chats, mock Chief, mock
    /// terminals) is allowed only when the developer asked for it: Mock data
    /// in Settings → Developer or `CMUX_MOBILE_MOCK_AUTH=1`, the same switches that
    /// sign in the local mock user. A live signed-in session never has it.
    public static var mockContentEnabled: Bool {
        mockContentEnabled(mockData: mockData, environment: ProcessInfo.processInfo.environment)
    }

    static func mockContentEnabled(mockData: Bool, environment: [String: String]) -> Bool {
        mockData || environment["CMUX_MOBILE_MOCK_AUTH"] == "1"
    }

    /// Settings → Developer's "Mock (layout only)" switch: on whenever mock
    /// data is in use (the stored switch or `CMUX_MOBILE_MOCK_AUTH=1`), and `forced`
    /// (locked on) when the launch environment sets it.
    public static func mockSwitch(stored: Bool, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (on: Bool, forced: Bool) {
        let forced = environment["CMUX_MOBILE_MOCK_AUTH"] == "1"
        return (stored || forced, forced)
    }

    /// Scripted demos a developer can pick for the next launch.
    public static let demos: [(id: String, title: String)] = [
        ("live", "Live tour"),
        ("workspaces", "Workspaces"),
        ("chief", "Chief"),
        ("chat-feed", "Feed and agent chat"),
        ("terminal", "Terminal"),
        ("drawer", "Team sidebar"),
    ]

    /// The demo picked for this launch, read and cleared once per process.
    public static let launchDemo: String? = {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: launchDemoKey), !name.isEmpty else { return nil }
        defaults.removeObject(forKey: launchDemoKey)
        return name
    }()
    #else
    /// Non-DEBUG builds have no mock content to enable.
    public static var mockContentEnabled: Bool { false }
    #endif
}
