#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

@MainActor
private final class SpacesSwitcherFixture {
    weak var original: WindowController?
    let profile: ProfileID
    let workspace: WorkspaceKey
    let windowID: String
    let showSpaces: Bool
    let visibility: SpacesVisibilityMode
    let width: CGFloat
    let presentation: SidebarPresentation

    init(original: WindowController, profile: ProfileID, workspace: WorkspaceKey, windowID: String,
         showSpaces: Bool, visibility: SpacesVisibilityMode, width: CGFloat, presentation: SidebarPresentation) {
        self.original = original
        self.profile = profile
        self.workspace = workspace
        self.windowID = windowID
        self.showSpaces = showSpaces
        self.visibility = visibility
        self.width = width
        self.presentation = presentation
    }
}

@MainActor private var activeSpacesSwitcherFixture: SpacesSwitcherFixture?

extension CaptureSceneRegistry {
    /// Removes the previous scene's fixture after the capture driver has finished its stills.
    func endSpacesSwitcher() async {
        guard let fixture = activeSpacesSwitcherFixture else { return }
        activeSpacesSwitcherFixture = nil
        let daemon = services.machines.local
        if let connection = daemon.connection,
           daemon.store.workspace(id: fixture.workspace.rawValue) != nil
            || services.windows.registry.members(of: fixture.windowID).contains(fixture.workspace.rawValue) {
            _ = try? await connection.closeWorkspace(fixture.workspace, endTerminals: true)
        }
        if let other = services.windows.controller(for: fixture.windowID) {
            services.windows.closeProgrammatically(other)
        }
        if let connection = daemon.connection {
            _ = try? await connection.deleteProfile(fixture.profile)
        }
        guard let original = fixture.original else { return }
        DesignSettings.shared.sidebarSections.showSpaces = fixture.showSpaces
        original.sidebar.container.sidebarView.spacesVisibility = fixture.visibility
        original.sidebar.container.restore(width: fixture.width, presentation: fixture.presentation)
        original.sidebar.container.sidebarView.renderNow()
    }

    /// Captures the original window after a second window owns a workspace in its own Space and the
    /// original sidebar has observed that window. All fixture IDs belong to this invocation.
    func renderSpacesSwitcher(_ params: [String: CmuxNextSettings.JSONValue], original: WindowController) async -> CmuxNextSettings.JSONValue {
        let daemon = services.machines.local
        guard let connection = daemon.connection, connection.supportsProfiles else {
            return .object(["error": .string("spaces-switcher requires a daemon with profiles")])
        }
        let profile = ProfileID.generate()
        let windowID = UUID().uuidString.lowercased()
        let workspace = WorkspaceKey.generate()
        let windows = services.windows
        let sidebar = original.sidebar.container.sidebarView
        let design = DesignSettings.shared
        let showSpaces = design.sidebarSections.showSpaces, visibility = sidebar.spacesVisibility
        let width = original.sidebar.model.width, presentation = original.sidebar.model.presentation
        activeSpacesSwitcherFixture = SpacesSwitcherFixture(original: original, profile: profile, workspace: workspace,
                                                            windowID: windowID, showSpaces: showSpaces,
                                                            visibility: visibility, width: width, presentation: presentation)
        do {
            _ = try await connection.createProfile(name: "Capture Space", id: profile, color: GroupColor.blue.rawValue)
        } catch {
            await endSpacesSwitcher()
            return .object(["error": .string("creating capture Space: \(error)")])
        }
        design.sidebarSections.showSpaces = true
        sidebar.spacesVisibility = .always
        original.sidebar.restore(width: 300, hidden: false)
        // `startWorkspace` claims the key before the daemon create runs. Keep the key registered
        // for cleanup even when the create throws after claiming it.
        var result: CmuxNextSettings.JSONValue
        do {
            let spawn = WorkspaceSpawn(name: "Capture", profile: profile, newTabPage: true, key: workspace)
            _ = try await windows.createWorkspace(spawn, on: daemon, into: windowID)
            windows.state(for: windowID).enterProfile(profile)
            windows.bringToFront(original)
            let key = SidebarProfileKey(profile.rawValue)
            let frames = BenchFrames()
            frames.start()
            let ready = await frames.settled(until: {
                guard let index = original.sidebar.model.profiles.firstIndex(where: { $0.id == key }) else {
                    return false
                }
                let hint = index < 8 ? index + 1 : (index == original.sidebar.model.profiles.count - 1 ? 9 : nil)
                return windows.controller(for: windowID)?.window != nil
                    && windows.registry.members(of: windowID).contains(workspace.rawValue)
                    && original.sidebar.model.activeProfileID != key
                    && (hint.map { expected in
                        sidebar.shortcutHintSpaceFrames.contains { $0.digit == expected }
                    } ?? true)
                    && sidebar.spaceWindowMarks.elsewhere[key]?.windowID == windowID
            }, start: .now, window: 100, deadline: 8_000)
            _ = frames.stop()
            if ready != nil {
                sidebar.renderNow()
                sidebar.layoutSubtreeIfNeeded()
                var snapshot = params
                snapshot["window"] = .string(original.state.id)
                result = await DebugWindowSnapshot.captureAsync(snapshot, services: services)
                if case .object(var report) = result {
                    report["scene"] = .string("spaces-switcher")
                    report["marked_space"] = .string(profile.rawValue)
                    report["other_window"] = .string(windowID)
                    result = .object(report)
                }
            } else {
                result = .object(["error": .string("the original switcher did not show the second window’s Space")])
            }
        } catch {
            result = .object(["error": .string("creating capture workspace: \(error)")])
        }
        if case .object(let report) = result, report["error"] != nil {
            await endSpacesSwitcher()
        }
        return result
    }
}
#endif
