import AppKit
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
import Testing

nonisolated private let viewDeviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddeeff"

/// Every view under `root`, depth first.
@MainActor
private func views(under root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + views(under: $0) }
}

/// The view under `root` with accessibility identifier `id`.
@MainActor
private func findView(_ id: String, under root: NSView) -> NSView? {
    views(under: root).first { $0.accessibilityIdentifier() == id }
}

/// The text of every label under `root`.
@MainActor
private func texts(under root: NSView) -> [String] {
    views(under: root).compactMap { ($0 as? NSTextField)?.stringValue }
}

/// Lets the views' Observation updates (main-actor tasks) run until `condition` holds.
@MainActor
private func settle(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Mac Screen's surfaces are AppKit (plans/cmux-next/no-swiftui-DESIGN.md): no hosting bridge,
/// and their controls run the models and follow them.
@MainActor @Suite(.serialized)
struct MacScreenAppKitViewTests {
    private func window(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.frame = window.contentView?.bounds ?? .zero
        content.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(content)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
    }

    @Test func noSurfaceBuildsAHostingView() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let home = pages.makeView(for: "home")
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences())
        let prompt = MacScreenApprovalPrompt()
        prompt.present = { _ in }
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", scope: .view)])
        let approval = MacScreenApprovalView(prompt: prompt)
        for root in [home, pane.view, approval] as [NSView] {
            for view in views(under: root) {
                #expect(!String(describing: type(of: view)).contains("Hosting"), "\(type(of: view)) under \(type(of: root))")
            }
        }
        pane.close()
        pages.tabClosed("home")
        prompt.update([])
    }

    @Test func homeSaysHowToSetUpAndFollowsTheHubAddress() async throws {
        let pages = makePages()
        pages.hubConfigured = true
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let window = window(tab)
        let signIn = MacScreenHomeSnapshot.setupNote(configured: true)
        let invalid = MacScreenHomeSnapshot.setupNote(configured: false)
        #expect(texts(under: tab).contains(signIn))
        #expect(texts(under: tab).contains(L.t("macScreen.home.yourDevices", "Your Devices")))
        // A model change redraws the page without a new view.
        pages.hubConfigured = false
        #expect(await settle { texts(under: tab).contains(invalid) })
        #expect(!texts(under: tab).contains(signIn))
        pages.tabClosed("home")
        window.close()
    }

    @Test func connectCardButtonsAskTheHubAndTheCardFollows() async throws {
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences())
        let window = window(pane.view)
        #expect(pane.model.card == .hubConnect)
        #expect(texts(under: pane.view.chrome.card).contains(String(format: L.t("macScreen.hub.connectTitle", "Connect to %@"), "Studio")))
        let full = try #require(findView("macScreen.hub.connectFull", under: pane.view.chrome.card) as? NSButton)
        #expect(findView("macScreen.hub.connectView", under: pane.view.chrome.card) is NSButton)
        // Return presses Full Control, as the card shows.
        #expect(full.keyEquivalent == "\r")
        full.performClick(nil)
        // Signed out: the hub refuses at once, and the card says so.
        #expect(pane.model.card == .hubRefused(.notSignedIn, requested: .full))
        let refusedTitle = L.t("macScreen.hub.signedOutTitle", "Not Signed In")
        #expect(await settle { texts(under: pane.view.chrome.card).contains(refusedTitle) })
        #expect(findView("macScreen.card.retry", under: pane.view.chrome.card) is NSButton)
        pane.view.layoutSubtreeIfNeeded()
        let card = pane.view.chrome.card.frame
        #expect(card.width == MacScreenCardView.width && card.height > 100)
        #expect(pane.view.screenRect.contains(CGPoint(x: card.midX, y: card.midY)))
        pane.close()
        window.close()
    }

    @Test func toolbarShowsTheNameAndHidesStreamControlsBeforeASession() async throws {
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences())
        let window = window(pane.view)
        let toolbar = pane.view.chrome.toolbar
        #expect(texts(under: toolbar).contains("Studio"))
        for id in ["macScreen.quality", "macScreen.sendKeys", "macScreen.disconnect", "macScreen.connect", "macScreen.viewOnly"] {
            #expect(findView(id, under: toolbar)?.isHidden == true, "\(id)")
        }
        pane.model.name = "Studio 2"
        #expect(await settle { texts(under: toolbar).contains("Studio 2") })
        pane.close()
        window.close()
    }

    @Test func approvalShowsTheRequestAndItsFourAnswers() throws {
        let prompt = MacScreenApprovalPrompt()
        prompt.present = { _ in }
        let fingerprint = String(repeating: "ab", count: 32)
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", viewerKeyFingerprint: fingerprint, scope: .full)])
        let view = MacScreenApprovalView(prompt: prompt)
        let shown = texts(under: view)
        #expect(shown.contains(String(format: L.t("macScreen.approval.titleFull", "%@ wants to control this Mac"), "Laptop")))
        #expect(shown.contains(DeviceIdentity.displayFingerprint(fingerprint)))
        for id in ["macScreen.approval.deny", "macScreen.approval.once", "macScreen.approval.alwaysView", "macScreen.approval.alwaysFull"] {
            #expect(findView(id, under: view) is NSButton, "\(id)")
        }
        let size = view.fittingSize
        #expect(size.width == MacScreenApprovalView.width && size.height > 100)
        prompt.update([])
    }
}
