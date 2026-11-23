import AppKit
import CmuxNextDesign
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
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
    views(under: root).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? ChromeLabel)?.stringValue }
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
@MainActor @Suite(.serialized, .closesItsWindows)
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
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences(), viewerLook: .current)
        let prompt = MacScreenApprovalPrompt()
        prompt.present = { _ in }
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", scope: .view)])
        let approval = CmuxDialogView(dialog: .standalone(MacScreenApprovalPrompt.spec(
            SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", scope: .view), error: nil)) { _ in })
        // The system's Liquid Glass view (macOS 26) hosts its own private views: not a cmux surface.
        func ownViews(under root: NSView) -> [NSView] {
            root.subviews.flatMap { view -> [NSView] in
                if #available(macOS 26.0, *), view is NSGlassEffectView { return [view] }
                return [view] + ownViews(under: view)
            }
        }
        for root in [home, pane.view, approval] as [NSView] {
            for view in ownViews(under: root) {
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
        let signIn = (MacScreenHomeSnapshot.setupDevices(configured: true).note ?? "")
        let invalid = (MacScreenHomeSnapshot.setupDevices(configured: false).note ?? "")
        #expect(texts(under: tab).contains(signIn))
        #expect(texts(under: tab).contains(L.t("macScreen.home.yourDevices", "Your Devices")))
        // A model change redraws the page without a new view.
        pages.hubConfigured = false
        #expect(await settle { texts(under: tab).contains(invalid) })
        #expect(!texts(under: tab).contains(signIn))
        pages.tabClosed("home")
        window.close()
    }

    /// Leo 2026-11-16 ("this needs to shut up"): an offline Mac has no buttons and no instructions; offline Macs
    /// fold under one Offline row that opens to their names.
    @Test func offlineMacsFoldUnderOneRowWithNoButtonsOrInstructions() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Air Blue", isPhone: false,
                                                   online: false, macScreenShared: true, access: MacScreenAccess(.ask))
        home.build(MacScreenHomeSnapshot(devices: .list([device]), sharingLook: .list))
        #expect(!texts(under: home).contains("Open cmux on Air Blue to share its screen."))
        #expect(findView("macScreen.home.view.Air Blue", under: home) == nil)
        #expect(findView("macScreen.home.control.Air Blue", under: home) == nil)
        #expect(findView("macScreen.home.name.Air Blue", under: home) == nil)
        let group = try #require(findView("macScreen.home.offlineGroup", under: home) as? NSButton)
        // The group says what it holds (a symbol-only button once drew just the chevron).
        #expect(group.attributedTitle.string == "Offline (1)")
        group.performClick(nil)
        #expect(findView("macScreen.home.name.Air Blue", under: home) != nil)
        #expect(findView("macScreen.home.view.Air Blue", under: home) == nil)
        pages.tabClosed("home")
    }

    /// The classic look (Debug Settings) keeps the rows from before 2026-11-16 for comparison.
    @Test func classicLookKeepsTheOldRows() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Air Blue", isPhone: false,
                                                   online: false, macScreenShared: true, access: MacScreenAccess(.ask))
        home.build(MacScreenHomeSnapshot(devices: .list([device]), sharingLook: .list, devicesLook: .classic))
        #expect(texts(under: home).contains("Open cmux on Air Blue to share its screen."))
        #expect((findView("macScreen.home.view.Air Blue", under: home) as? NSButton)?.isEnabled == false)
        pages.tabClosed("home")
    }

    /// A usable Mac says nothing about access: name, dot and the buttons.
    @Test func askAccessSaysNothing() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Studio", isPhone: false,
                                                   online: true, macScreenShared: true, access: MacScreenAccess(.ask))
        home.build(MacScreenHomeSnapshot(devices: .list([device]), sharingLook: .list))
        let shown = texts(under: home)
        #expect(!shown.contains("The first connect asks on that Mac."))
        #expect(!shown.contains { $0.hasPrefix("Your access") })
        #expect(shown.contains("Studio"))
        #expect((findView("macScreen.home.control.Studio", under: home) as? NSButton)?.isEnabled == true)
        pages.tabClosed("home")
    }

    @Test func firstUseGuideNamesTheTwoSharingSteps() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        let sharing = MacScreenHomeSnapshot.Sharing(isSharing: false, busy: false, screenRecordingGranted: false,
                                                     accessibilityGranted: false, showFirstUse: true)
        home.build(MacScreenHomeSnapshot(sharing: sharing, sharingLook: .list))
        #expect(texts(under: home).contains("First time? 1. Turn on Allow Mac Screen on the other Mac. 2. Click View Only or Full Control here."))
        pages.tabClosed("home")
    }

    private func homeView(_ devices: [MacScreenHomeSnapshot.Device]) throws -> (MacScreenPages, MacScreenHomeView) {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        let tab = pages.makeView(for: "home")
        let home = try #require(views(under: tab).compactMap { $0 as? MacScreenHomeView }.first)
        home.build(MacScreenHomeSnapshot(devices: .list(devices), sharingLook: .list))
        return (pages, home)
    }

    /// A hub device maps to a row's values; its offline word counts only while this Mac's hub link is up.
    @Test func hubDevicesMapToRowsAndOfflineIsUnknownWhileTheHubReconnects() {
        let mac = HubDevice(id: "mac", name: "Office", platform: .macos, macScreenShared: true, online: false)
        let ask = MacScreenAccess(.ask)
        let connected = MacScreenHomeSnapshot.device(mac, access: ask, hubConnected: true)
        #expect(connected == MacScreenHomeSnapshot.Device(id: "mac", name: "Office", isPhone: false, online: false,
                                                           macScreenShared: true, access: ask, onlineKnown: true))
        #expect(!MacScreenHomeSnapshot.device(mac, access: ask, hubConnected: false).onlineKnown)
    }

    /// While the hub reconnects, a Mac last seen offline keeps View Only and Full Control and says nothing about it.
    @Test func aMacOfUnknownOnlineStateCanStillBeOpened() throws {
        let device = MacScreenHomeSnapshot.Device(id: viewDeviceID, name: "Office", isPhone: false, online: false,
                                                   macScreenShared: true, access: MacScreenAccess(.ask), onlineKnown: false)
        let (pages, home) = try homeView([device])
        #expect((findView("macScreen.home.view.Office", under: home) as? NSButton)?.isEnabled == true)
        #expect((findView("macScreen.home.control.Office", under: home) as? NSButton)?.isEnabled == true)
        #expect(!texts(under: home).contains("Open cmux on Office to share its screen."))
        pages.tabClosed("home")
    }

    /// Online, sharing and allowed: both buttons work. Sharing off: one short word, no buttons. Offline: folded.
    @Test func sharingOffSaysOneWordAndOnlineSharedRowsWork() throws {
        let ask = MacScreenAccess(.ask)
        let (pages, home) = try homeView([
            MacScreenHomeSnapshot.Device(id: "a", name: "Studio", isPhone: false, online: true, macScreenShared: true, access: ask),
            MacScreenHomeSnapshot.Device(id: "b", name: "Office", isPhone: false, online: true, macScreenShared: false, access: ask),
            MacScreenHomeSnapshot.Device(id: "c", name: "Den", isPhone: false, online: false, macScreenShared: true, access: ask),
        ])
        #expect((findView("macScreen.home.view.Studio", under: home) as? NSButton)?.isEnabled == true)
        #expect((findView("macScreen.home.control.Studio", under: home) as? NSButton)?.isEnabled == true)
        #expect((findView("macScreen.home.notShared.Office", under: home) as? NSTextField)?.stringValue == "Sharing off")
        #expect(findView("macScreen.home.view.Office", under: home) == nil)
        #expect(findView("macScreen.home.name.Den", under: home) == nil)
        #expect((findView("macScreen.home.offlineGroup", under: home) as? NSButton) != nil)
        pages.tabClosed("home")
    }

    /// A Mac that blocks this one says so even while its sharing is off: turning sharing on would not let this Mac in.
    @Test func aBlockingMacSaysItBlocksEvenWithSharingOff() throws {
        let device = MacScreenHomeSnapshot.Device(id: "a", name: "Office", isPhone: false, online: true,
                                                   macScreenShared: false, access: MacScreenAccess(.none))
        let (pages, home) = try homeView([device])
        #expect(findView("macScreen.home.blocked.Office", under: home) != nil)
        #expect(!texts(under: home).contains("Turn on Allow Mac Screen on Office to share its screen."))
        pages.tabClosed("home")
    }

    /// Your Devices lists a Linux desktop and a Windows PC with their own glyphs (Leo 2026-11-16: "i dont see
    /// windows nor linux"). Linux opens like a Mac; a Windows PC, which this Mac cannot view yet, says so with no buttons.
    @Test func linuxAndWindowsRowsShowTheirPlatform() throws {
        let full = MacScreenAccess(.full)
        let linux = MacScreenHomeSnapshot.Device(id: "l", name: "Box", isPhone: false, online: true, macScreenShared: true,
                                                  access: full, platform: .linux)
        let windows = MacScreenHomeSnapshot.Device(id: "w", name: "PC", isPhone: false, online: true, macScreenShared: true,
                                                    access: full, platform: .windows)
        #expect(linux.glyph == "server.rack")
        #expect(windows.glyph == "pc")
        #expect(MacScreenHomeSnapshot.Device(id: "m", name: "Mac", isPhone: false, online: true, macScreenShared: true,
                                             access: full).glyph == "desktopcomputer")
        let (pages, home) = try homeView([linux, windows])
        #expect((findView("macScreen.home.control.Box", under: home) as? NSButton)?.isEnabled == true)
        #expect(findView("macScreen.home.notViewable.PC", under: home) != nil)
        #expect(findView("macScreen.home.control.PC", under: home) == nil)
        #expect(findView("macScreen.home.view.PC", under: home) == nil)
        pages.tabClosed("home")
    }

    /// Macs are listed whether or not they are online or sharing; a phone only when it shares (never, today).
    @Test func listsEveryMacButOnlySharingPhones() {
        let devices = [
            HubDevice(id: "mac-offline", name: "Office", platform: .macos, macScreenShared: true, online: false),
            HubDevice(id: "mac-off", name: "Studio", platform: .macos, macScreenShared: false, online: true),
            HubDevice(id: "phone", name: "Phone", platform: .ios, macScreenShared: false, online: true),
        ]
        #expect(MacScreenHomeSnapshot.listed(devices).map(\.id) == ["mac-offline", "mac-off"])
    }

    @Test func connectCardButtonsAskTheHubAndTheCardFollows() async throws {
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences(), viewerLook: .current)
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
        let pane = MacScreenPane(hubDevice: MacScreenHubViewer(deviceID: viewDeviceID) { nil }, name: "Studio", preferences: ScreenPreferences(), viewerLook: .current)
        let window = window(pane.view)
        let toolbar = pane.view.chrome.toolbar
        #expect(texts(under: toolbar).contains("Studio"))
        for id in ["macScreen.quality", "macScreen.sendKeys", "macScreen.disconnect", "macScreen.connect", "macScreen.access", "macScreen.fullScreen", "macScreen.more"] {
            #expect(findView(id, under: toolbar)?.isHidden == true, "\(id)")
        }
        pane.model.name = "Studio 2"
        #expect(await settle { texts(under: toolbar).contains("Studio 2") })
        pane.close()
        window.close()
    }

    /// The device-control prompt is the cmux dialog card on its glass (Lawrence 2026-11-17, "think liquid glass"),
    /// worded plainly (Leo, 2026-11-16: "super ugly", "i dont want to have to click share this mac allow every single
    /// time"): who asks and what it can do, what Allow keeps, the key in two lines of four groups on a well, and three
    /// answers stacked the card's width: Allow first (the one fill, the hub's Always; no key: only the person's click
    /// allows), Allow Only This Time, and Not Now last as quiet text (Escape).
    @Test func approvalAsksPlainlyWithAllowFirst() throws {
        let prompt = MacScreenApprovalPrompt()
        defer { prompt.update([]) }
        let fingerprint = "78be18e0c08c9c4d7443d95e2db68074" + String(repeating: "ab", count: 16)
        prompt.update([SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", viewerKeyFingerprint: fingerprint, scope: .full)])
        let view = try #require(prompt.dialogView, "the prompt draws the cmux dialog card")
        view.window?.contentView?.layoutSubtreeIfNeeded()
        let shown = texts(under: view)
        #expect(shown.contains(String(format: L.t("macScreen.approval.titleFull", "%@ wants to control this Mac"), "Laptop")))
        #expect(shown.contains(L.t("macScreen.approval.bodyFull", "It can see your screen and use your mouse and keyboard.")))
        #expect(shown.contains("78BE 18E0 C08C 9C4D\n7443 D95E 2DB6 8074"))
        #expect(view.spec.layout == .stacked)
        #expect(views(under: view).contains { $0 is OverlaySurfaceView }, "on the dialog glass")
        let ids = ["alwaysFull", "once", "deny"]
        #expect(view.spec.buttons.map(\.id) == ids)
        #expect(view.spec.buttons.map(\.title) == [MacScreenApprovalWords.allow, MacScreenApprovalWords.onlyThisTime,
                                                   MacScreenApprovalWords.notNow])
        #expect(view.spec.buttons.map(\.personOnly) == [true, true, false])
        let buttons = try ids.map { try #require(view.buttonView($0), "\($0)") }
        let frames = buttons.map { $0.convert($0.bounds, to: nil) }
        for (upper, lower) in zip(frames, frames.dropFirst()) {
            #expect(lower.maxY <= upper.minY)
            #expect(lower.width == upper.width && lower.minX == upper.minX)
        }
        #expect(buttons[0].keyHint == nil && buttons[2].keyHint == .escape && buttons[2].isQuiet)
        let card = try #require(prompt.panelFrame)
        #expect(abs(card.width - view.fittingSize.width) < 1 && card.height > 100)
    }

    /// Allow is the hub's Always at the scope asked for: View Only for a request to see, Full Control
    /// for a request to control, so the same Mac's next request of that scope is not asked.
    @Test func allowRemembersTheScopeAskedFor() {
        for (scope, choice, stored) in [(SessionScope.view, MacScreenApprovalChoice.alwaysView, SessionScope.view),
                                        (.full, .alwaysFull, .full)] {
            let request = SessionRequest(id: "s", viewerId: "v", viewerName: "Laptop", scope: scope)
            let words = MacScreenApprovalWords(request)
            #expect(words.allowChoice == choice)
            #expect(MacScreenApprovalPrompt.spec(request, error: nil).buttons.first?.id == choice.rawValue)
            let answer = words.allowChoice.answer(requested: scope)
            #expect(answer.decision == .always && answer.scope == stored && answer.thenPermission == nil)
        }
    }

    @Test func aFailedAnswerShowsInTheCard() {
        let spec = MacScreenApprovalPrompt.spec(SessionRequest(id: "s1", viewerId: "v1", viewerName: "Laptop", scope: .view),
                                                error: "The answer did not reach the device hub. Try again.")
        #expect(spec.error == "The answer did not reach the device hub. Try again.")
        #expect(spec.title == String(format: L.t("macScreen.approval.titleView", "%@ wants to see this Mac"), "Laptop"))
        #expect(spec.fields.isEmpty, "no fingerprint, no well")
    }
}
