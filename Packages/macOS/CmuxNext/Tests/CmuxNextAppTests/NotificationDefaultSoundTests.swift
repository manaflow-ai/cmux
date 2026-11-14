import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextNotifications
import CmuxNextSettings
import Foundation
import Testing
import UserNotifications

/// https://github.com/manaflow-ai/cmux/issues/42221: with `notifications.sound` at `"default"` a
/// notification sounds as it does in cmux classic. A banner carries the system sound. When no
/// banner shows, or macOS refuses one, cmux plays the sound itself (`banner: false`), unless the
/// person denied cmux notifications.
@MainActor
struct NotificationDefaultSoundTests {
    @MainActor private final class Recorder: NotificationSoundPlaying {
        var played: [(name: String, banner: Bool)] = []
        func play(_ name: String, volume: Double, banner: Bool) { played.append((name, banner)) }
    }

    private static func service(desktop: DesktopNotificationMode, recorder: Recorder) -> NotificationCenterService {
        _ = NSApplication.shared
        let service = NotificationCenterService()
        service.terminalNotificationsEnabled = { true }
        service.preferences.desktop = desktop
        service.soundGate = NotificationSoundGate(player: recorder)
        return service
    }

    /// An agent finishing in a tab the person does not see.
    private static func arriveOnTab(desktop: DesktopNotificationMode, recorder: Recorder) throws -> NotificationCenterService {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let wire = #"{"notification":5,"title":"Claude finished","body":"","level":"info","surface":1,"source":"agent"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        store.apply(.notification(notification))
        let workspace = try #require(store.workspaces.first)
        let paneModel = try #require(workspace.screens.first?.panes.first)
        let located = LocatedTab(tab: try #require(paneModel.tabs.first), pane: paneModel, workspace: workspace)
        let service = Self.service(desktop: desktop, recorder: recorder)
        let hidden = TerminalVisibility(tabSelected: false, paneOnScreen: false, windowShown: false, appActive: true)
        service.arrive(notification, located: located, visibility: hidden)
        return service
    }

    /// `cmux notify --workspace ws_…`: no tab.
    private static func arriveOnWorkspace(desktop: DesktopNotificationMode, recorder: Recorder) throws -> NotificationCenterService {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, resourceID: "ws_00000000000000000000000000000042", name: "build", screens: [screen]),
        ]))
        let wire = #"{"notification":9,"title":"Deploy done","body":"","level":"info","workspace_id":"ws_00000000000000000000000000000042","source":"cli"}"#
        let notification = try JSONDecoder().decode(DaemonNotification.self, from: Data(wire.utf8))
        let workspace = try #require(NotificationCenterService.workspace(of: notification, in: store))
        let service = Self.service(desktop: desktop, recorder: recorder)
        service.arrive(notification, located: nil, workspace: workspace)
        return service
    }

    @Test func aBannerCarriesTheDefaultSoundAndCmuxPlaysNothingMore() throws {
        let recorder = Recorder()
        let service = try Self.arriveOnTab(desktop: .always, recorder: recorder)
        #expect(service.desktop.posted.last?.sound == "default", "the banner carries the system sound")
        #expect(recorder.played.isEmpty, "a second sound would double the banner's")
    }

    @Test func aTabNotificationWithoutABannerPlaysTheDefaultSoundItself() throws {
        let recorder = Recorder()
        let service = try Self.arriveOnTab(desktop: .never, recorder: recorder)
        #expect(service.desktop.posted.isEmpty)
        #expect(recorder.played.map(\.name) == ["default"])
        #expect(recorder.played.map(\.banner) == [false], "no banner shows, so no banner can carry the default sound")
    }

    @Test func aWorkspaceNotificationWithoutABannerPlaysTheDefaultSoundItself() throws {
        let recorder = Recorder()
        let service = try Self.arriveOnWorkspace(desktop: .never, recorder: recorder)
        #expect(service.desktop.posted.isEmpty)
        #expect(recorder.played.map(\.name) == ["default"], "a workspace notification with no banner played no sound")
        #expect(recorder.played.map(\.banner) == [false])
    }

    @Test func aBannerMacOSRefusedPlaysTheDefaultSoundUnlessNotificationsAreDenied() {
        let notifier = DesktopNotifier()
        var beeps = 0
        notifier.playUnshownDefaultSound = { beeps += 1 }
        notifier.bannerRefused(defaultSound: true, status: .notDetermined, asksPermission: true)
        #expect(beeps == 1, "a banner refused before authorization was answered must still sound")
        notifier.bannerRefused(defaultSound: true, status: .authorized, asksPermission: true)
        #expect(beeps == 2, "a banner the center failed to add must still sound")
        notifier.bannerRefused(defaultSound: true, status: .denied, asksPermission: true)
        #expect(beeps == 2, "a person who denied cmux notifications hears nothing, as in classic")
        notifier.bannerRefused(defaultSound: false, status: .notDetermined, asksPermission: true)
        #expect(beeps == 2, "a silent banner or a custom sound (played by the player) adds nothing")
        notifier.bannerRefused(defaultSound: true, status: .notDetermined, asksPermission: false)
        #expect(beeps == 2, "a GUI job never asks for permission, so its refused banners stay silent")
    }
}
