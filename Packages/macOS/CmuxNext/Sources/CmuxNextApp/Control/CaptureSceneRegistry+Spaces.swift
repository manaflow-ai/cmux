#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

extension CaptureSceneRegistry {
    /// Captures the original window after a second window owns a workspace in its own Space and the
    /// original sidebar has observed that window. All fixture IDs belong to this invocation.
    func renderSpacesSwitcher(_ params: [String: CmuxNextSettings.JSONValue], original: WindowController) async -> CmuxNextSettings.JSONValue {
        let daemon = services.machines.local
        guard let connection = daemon.connection, connection.supportsProfiles else {
            return .object(["error": .string("spaces-switcher requires a daemon with profiles")])
        }
        let profile = ProfileID.generate()
        do {
            _ = try await connection.createProfile(name: "Capture Space", id: profile, color: GroupColor.blue.rawValue)
        } catch {
            return .object(["error": .string("creating capture Space: \(error)")])
        }
        let windowID = UUID().uuidString.lowercased()
        let workspace = WorkspaceKey.generate()
        let windows = services.windows
        let sidebar = original.sidebar.container.sidebarView
        let design = DesignSettings.shared
        let showSpaces = design.sidebarSections.showSpaces, visibility = sidebar.spacesVisibility
        let width = original.sidebar.model.width, presentation = original.sidebar.model.presentation
        defer {
            design.sidebarSections.showSpaces = showSpaces
            sidebar.spacesVisibility = visibility
            original.sidebar.container.restore(width: width, presentation: presentation)
            sidebar.renderNow()
        }
        design.sidebarSections.showSpaces = true
        sidebar.spacesVisibility = .always
        original.sidebar.restore(width: 300, hidden: false)
        var createdWorkspace = false
        var result: CmuxNextSettings.JSONValue
        do {
            let spawn = WorkspaceSpawn(name: "Capture", profile: profile, newTabPage: true, key: workspace)
            _ = try await windows.createWorkspace(spawn, on: daemon, into: windowID)
            createdWorkspace = true
            windows.state(for: windowID).enterProfile(profile)
            windows.bringToFront(original)
            let key = SidebarProfileKey(profile.rawValue)
            let frames = BenchFrames()
            frames.start()
            let ready = await frames.settled(until: {
                windows.controller(for: windowID)?.window != nil
                    && windows.registry.members(of: windowID).contains(workspace.rawValue)
                    && original.sidebar.model.activeProfileID != key
                    && original.sidebar.model.profiles.last?.id == key
                    && SpaceSwitcherStyle.tunable.value.marksOtherWindows
                    && sidebar.shortcutHintSpaceFrames.contains { $0.digit == min(original.sidebar.model.profiles.count, 9) }
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
        var cleanupErrors: [String] = []
        if createdWorkspace {
            do { _ = try await connection.closeWorkspace(workspace, endTerminals: true) }
            catch { cleanupErrors.append("workspace: \(error)") }
        }
        if let other = windows.controller(for: windowID) { windows.closeProgrammatically(other) }
        do { _ = try await connection.deleteProfile(profile) }
        catch { cleanupErrors.append("Space: \(error)") }
        if !cleanupErrors.isEmpty {
            return .object(["error": .string(cleanupErrors.joined(separator: ", ")), "snapshot": result])
        }
        return result
    }
}
#endif
