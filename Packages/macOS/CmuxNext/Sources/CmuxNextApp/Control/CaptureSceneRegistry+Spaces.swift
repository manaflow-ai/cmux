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
final class SpacesSwitcherFixture {
    weak var original: WindowController?
    let profile: ProfileID
    let workspace: WorkspaceKey
    let windowID: String
    let showSpaces: Bool
    let visibility: SpacesVisibilityMode
    let width: CGFloat
    let presentation: SidebarPresentation

    init(original: WindowController) {
        self.original = original
        self.profile = ProfileID.generate()
        self.workspace = WorkspaceKey.generate()
        self.windowID = UUID().uuidString.lowercased()
        self.showSpaces = DesignSettings.shared.sidebarSections.showSpaces
        self.visibility = original.sidebar.container.sidebarView.spacesVisibility
        self.width = original.sidebar.model.width
        self.presentation = original.sidebar.model.presentation
    }
}

extension CaptureSceneRegistry {
    /// Removes the previous scene's fixture after the capture driver has finished its stills.
    func endSpacesSwitcher() async -> [String] {
        guard let fixture = services.spacesSwitcherFixture else { return [] }
        var errors: [String] = []
        let daemon = services.machines.local
        let hasWorkspace = daemon.store.workspace(id: fixture.workspace.rawValue) != nil
            || services.windows.registry.members(of: fixture.windowID).contains(fixture.workspace.rawValue)
        if hasWorkspace {
            if let connection = daemon.connection {
                do { _ = try await connection.closeWorkspace(fixture.workspace, endTerminals: true) }
                catch { errors.append("workspace: \(error)") }
            } else {
                errors.append("daemon disconnected while closing capture workspace")
            }
        }
        if let other = services.windows.controller(for: fixture.windowID) {
            services.windows.closeProgrammatically(other)
        }
        if errors.isEmpty {
            if let connection = daemon.connection {
                do { _ = try await connection.deleteProfile(fixture.profile) }
                catch { errors.append("Space: \(error)") }
            } else {
                errors.append("daemon disconnected while deleting capture Space")
            }
        }
        // The global setting belongs to the capture invocation even if its original window was closed.
        DesignSettings.shared.sidebarSections.showSpaces = fixture.showSpaces
        if let original = fixture.original {
            original.sidebar.container.sidebarView.spacesVisibility = fixture.visibility
            original.sidebar.container.restore(width: fixture.width, presentation: fixture.presentation)
            original.sidebar.container.sidebarView.renderNow()
        }
        if errors.isEmpty { services.spacesSwitcherFixture = nil }
        return errors
    }

    /// Captures the original window after a second window owns a workspace in its own Space and the
    /// original sidebar has observed that window. All fixture IDs belong to this invocation.
    func renderSpacesSwitcher(_ params: [String: CmuxNextSettings.JSONValue], original: WindowController) async -> CmuxNextSettings.JSONValue {
        let daemon = services.machines.local
        guard let connection = daemon.connection, connection.supportsProfiles else {
            return .object(["error": .string("spaces-switcher requires a daemon with profiles")])
        }
        let fixture = SpacesSwitcherFixture(original: original)
        let profile = fixture.profile
        let windowID = fixture.windowID
        let workspace = fixture.workspace
        let windows = services.windows
        let sidebar = original.sidebar.container.sidebarView
        let design = DesignSettings.shared
        do {
            _ = try await connection.createProfile(name: "Capture Space", id: profile, color: GroupColor.blue.rawValue)
        } catch {
            return .object(["error": .string("creating capture Space: \(error)")])
        }
        services.spacesSwitcherFixture = fixture
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
                    && sidebar.spaceDotIsDrawn(key)
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
        if case .object(var report) = result {
            let shouldEnd = report["error"] != nil || params["path"]?.stringValue != nil
            if shouldEnd {
                let cleanupErrors = await endSpacesSwitcher()
                if !cleanupErrors.isEmpty {
                    if report["error"] == nil { report["error"] = .string("spaces-switcher fixture cleanup failed") }
                    report["cleanup_errors"] = .array(cleanupErrors.map(CmuxNextSettings.JSONValue.string))
                }
                result = .object(report)
            }
        } else if params["path"]?.stringValue != nil {
            _ = await endSpacesSwitcher()
        }
        return result
    }
}
#endif
