import AppKit
import CmuxNextDevices
@testable import CmuxNextDesign
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import CmuxScreenKit
import CmuxTheme
import Foundation
import ImageIO
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct MacScreenViewerControlsTests {
    private func pane(scope: SessionScope = .view) -> MacScreenPane {
        let viewer = MacScreenHubViewer(deviceID: "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff") { nil }
        viewer.phase = .streaming(sessionID: "layout-session", scope: scope)
        return MacScreenPane(hubDevice: viewer, name: "Studio MacBook Pro", preferences: ScreenPreferences())
    }

    private func button(_ id: String, in pane: MacScreenPane) throws -> NSButton {
        try #require(pane.view.chrome.toolbar.subviews.first { $0.accessibilityIdentifier() == id } as? NSButton)
    }

    @Test func requestingControlUsesTheHostApprovalPath() throws {
        let pane = pane()
        let access = try #require(button("macScreen.access", in: pane) as? MacScreenMenuButton)
        #expect(access.isEnabled)
        let menu = access.makeMenu()
        #expect(menu.items.map(\.state) == [.on, .off])
        menu.performActionForItem(at: 0)
        #expect(pane.model.hub?.phase == .streaming(sessionID: "layout-session", scope: .view))
        menu.performActionForItem(at: 1)
        // No signed-in hub: requesting control must refuse, never elevate the view ticket.
        #expect(pane.model.hub?.phase == .refused(.notSignedIn, requested: .full))
        #expect(!pane.model.isLive)
        pane.close()
    }

    @Test func switchingToViewOnlyRequestsANewRestrictedSession() throws {
        let pane = pane(scope: .full)
        let access = try #require(button("macScreen.access", in: pane) as? MacScreenMenuButton)
        access.makeMenu().performActionForItem(at: 0)
        #expect(pane.model.hub?.phase == .refused(.notSignedIn, requested: .view))
        pane.close()
    }

    @Test func fullScreenButtonDispatchesOnce() throws {
        let pane = pane()
        var presses = 0
        pane.view.chrome.actions.fullScreen = { presses += 1 }
        try button("macScreen.fullScreen", in: pane).performClick(nil)
        #expect(presses == 1)
        pane.close()
    }

    @Test(arguments: [240.0, 320.0, 600.0, 900.0, 1400.0])
    func controlsStayInsideThePaneAndVideoStartsBelowThem(width: Double) throws {
        let pane = pane()
        pane.view.frame = CGRect(x: 0, y: 0, width: width, height: 640)
        pane.view.layoutSubtreeIfNeeded()
        let toolbar = pane.view.chrome.toolbar
        let controls = toolbar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        for (index, control) in controls.enumerated() {
            #expect(toolbar.bounds.contains(control.frame), "\(control.accessibilityIdentifier() ?? "button") at \(width)")
            for other in controls.dropFirst(index + 1) { #expect(!control.frame.intersects(other.frame)) }
        }
        #expect(pane.view.capture.frame.minY == toolbar.frame.maxY)
        #expect(pane.view.screenRect == pane.view.capture.frame)
        // Resizing returns to the same arrangement; compact measurement cannot change its breakpoint.
        let frames = controls.map(\.frame)
        pane.view.needsLayout = true
        toolbar.needsLayout = true
        pane.view.layoutSubtreeIfNeeded()
        #expect(controls.map(\.frame) == frames)
        pane.close()
    }

    /// The same production renderer in three arrangements, each in light and dark.
    /// These are layout fixtures, not evidence of an authenticated live connection.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-viewer-controls-gallery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var captures: [String: Data] = [:]
        for (mode, dark) in [("light", false), ("dark", true)] {
            for variant in ["inline", "stacked", "compact"] {
                let pane = pane()
                let toolbar = pane.view.chrome.toolbar
                let width = variant == "inline" ? toolbar.expandedWidth + 100 : variant == "stacked" ? toolbar.expandedWidth - 64 : 360
                let theme = dark ? "Soft Blue" : "Soft Blue Light"
                let input = try AANestedGroupsGalleryTests.input(theme)
                _ = ThemeScope.app.store.apply(input)
                let scope = ThemeScope(level: .room)
                scope.setOverride(ThemeSpec(theme), input: input, animated: false)
                scope.root(toolbar)
                toolbar.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbar.height(for: width))
                toolbar.resolveColors()
                toolbar.layoutSubtreeIfNeeded()
                let rep = try #require(toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds))
                toolbar.cacheDisplay(in: toolbar.bounds, to: rep)
                let image = try #require(rep.cgImage)
                let url = out.appending(path: "\(variant)-\(mode).png")
                let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, image, nil)
                #expect(CGImageDestinationFinalize(dest))
                captures["\(variant)-\(mode).png"] = try Data(contentsOf: url)
                pane.close()
            }
        }
        let artifact = AANestedGroupsGalleryTests.packageRoot.appending(path: "mac-screen-viewer-controls-gallery.json")
        try JSONEncoder().encode(captures).write(to: artifact, options: .atomic)
        print("Screen sharing controls gallery: \(out.path); artifact: \(artifact.path)")
    }
}
