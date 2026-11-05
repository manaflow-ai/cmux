#if DEBUG || CMUX_BENCH_HOOKS
import CmuxHomeCore
import CmuxNextHomeEngine
import CmuxNextSettings

/// `home-chief-profile-details`, `-settings` and `-computer`: Home at the Chief with its profile panel
/// open beside the chat at that tab. Computer shows a fixture computer (running, a desktop drawn by the
/// app, the person in control), since capture minis have no Cloud Chief with one; Details and Settings
/// show the showcase Chief's real card.
extension CaptureSceneRegistry {
    static let chiefProfileScenes: [String: HomeChiefProfileTab] = [
        "home-chief-profile-details": .details, "home-chief-profile-settings": .settings, "home-chief-profile-computer": .computer,
    ]

    /// The scene's snapshot, or nil when `name` is no profile scene.
    func renderChiefProfile(_ name: String, params: [String: CmuxNextSettings.JSONValue], windowID: String) async -> CmuxNextSettings.JSONValue? {
        guard let tab = Self.chiefProfileScenes[name] else { return nil }
        guard let controller = services.windows.controller(for: windowID), let chief = TopHomePageView.chief(services.home) else {
            return .object(["error": .string("no capture window or no Chief conversation"), "scene": .string(name)])
        }
        TopPages.show(.home, services: services, in: controller.state)
        guard let page = controller.topPages.views[.home] as? TopHomePageView else { return .object(["error": .string("Home page did not open")]) }
        page.show(ConversationID(chief))
        let fixture = tab == .computer
        var opened = false
        frames.start()
        let settled = await frames.settled(until: {
            guard let host = page.host else { return false }
            if !opened { opened = host.debugShowProfile(tab, fixtureComputer: fixture) }
            return opened && host.panel.view.debugSettled(tab, fixtureComputer: fixture)
        }, start: ContinuousClock.now, window: 100, deadline: 10_000)
        let frameStats = frames.stop()
        defer { page.host?.closeProfile() }
        guard settled != nil else {
            return .object(["error": .string("the Chief's profile panel did not settle"), "scene": .string(name), "opened": .bool(opened), "frames": frameStats])
        }
        var snapshotParams = params
        snapshotParams["window"] = .string(windowID)
        let snapshot = await DebugWindowSnapshot.captureAsync(snapshotParams, services: services)
        guard case .object(var result) = snapshot else { return snapshot }
        result["scene"] = .string(name)
        result["tab"] = .string(tab.rawValue)
        result["frames"] = frameStats
        return .object(result)
    }
}
#endif
