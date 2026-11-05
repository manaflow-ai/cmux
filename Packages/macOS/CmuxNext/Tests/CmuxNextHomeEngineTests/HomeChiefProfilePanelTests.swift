import AppKit
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief profile panel (Lawrence 2026-11-04, after Grok's bot panel): Details · Settings ·
/// Computer, every setting of the old settings card in exactly one tab, the Computer tab's gates,
/// and the control bar that hands the computer between the Chief and the person.
@MainActor @Suite(.serialized) struct HomeChiefProfilePanelTests {
    private static func card() -> HomeChiefSettingsView {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-profile-\(UUID().uuidString)")
        let card = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        card.addAppearanceRow("Show Chief Pet", control: NSSwitch())
        return card
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { subviews(of: $0) }
    }

    private static func link(_ id: String, in view: NSView) -> NSView? {
        subviews(of: view).first { $0.accessibilityIdentifier() == id }
    }

    @Test func everySettingIsInExactlyOneTab() throws {
        let card = Self.card()
        let expected: [(String, NSView?, HomeChiefProfileTab)] = [
            ("avatar", card.avatarButton, .details), ("name", card.nameField, .details), ("where it runs", card.place, .details),
            ("Switch to", card.hostSwitch, .details), ("Primary Chief", card.primaryBox, .details), ("Runs On", card.teleportRow, .details),
            ("Connections", card.connections, .details), ("Vault", card.vault, .details), ("Diagnostics", card.diagnosticsToggle, .details),
            ("diagnostics", card.diagnostics, .details), ("Edit Chief", Self.link("cmux.home.chief.editChief", in: card), .details),
            ("Harness", card.harness, .settings), ("harness hint", card.harnessHint, .settings), ("Model", card.model, .settings),
            ("Effort", card.effort, .settings), ("Speed", card.speed, .settings), ("Reactions", card.reactionRows, .settings),
            ("Appearance", card.appearanceRows, .settings), ("All Chief Settings", Self.link("cmux.home.chief.allSettings", in: card), .settings),
            ("Computer Use", card.computerPicker, .computer), ("Show Desktop", card.computerDesktop, .computer),
        ]
        for (name, view, tab) in expected {
            let view = try #require(view, "\(name) is missing")
            #expect(card.tab(of: view) == tab, "\(name) is in \(String(describing: card.tab(of: view))), not \(tab)")
        }
        // Nothing of the card's is outside the tabs but the note that says why a change failed.
        let outside = card.stack.arrangedSubviews.filter { view in !HomeChiefProfileTab.allCases.contains { card.sections[$0] === view } }
        #expect(outside == [card.failure as NSView])
    }

    @Test func eachTabShowsOnlyItsSection() {
        let card = Self.card()
        let panel = HomeChiefProfileView(settings: card)
        #expect(panel.tabs.shown == HomeChiefProfileTab.allCases)
        #expect(panel.selectedTab == .details)
        #expect(panel.avatar === card.avatarButton, "the header's avatar is the card's, whose menu changes the picture")
        #expect(panel.avatar.isEnabled)
        for tab in HomeChiefProfileTab.allCases {
            panel.tabs.button(tab)?.performClick(nil)
            #expect(panel.selectedTab == tab)
            for other in HomeChiefProfileTab.allCases { #expect(card.sections[other].isHidden == (other != tab)) }
            #expect(panel.computerPane.isHidden == (tab != .computer))
            #expect(panel.details.isHidden, "the panel's Details are the card's")
        }
        panel.select(.settings)
        #expect(panel.selectedTab == .settings)
    }

    @Test func theExpandedPageHasNoSettingsTab() {
        let page = HomeChiefProfileView()
        #expect(page.isExpanded)
        #expect(page.tabs.shown == [.details, .computer])
        #expect(page.selectedTab == .computer)
        page.select(.settings)
        #expect(page.selectedTab == .computer)
        #expect(page.tabs.button(.settings)?.isHidden == true)
    }

    @Test func theComputerGates() {
        #expect(HomeChiefProfileView.gate(paid: false, cloudChief: false, hasComputer: false, machine: true) == .paywall)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: false, hasComputer: false) == .needsCloudChief)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: false, hasComputer: false, machine: true) == .machine)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: true, hasComputer: false, machine: true) == .notSetUp)
        #expect(HomeChiefProfileView.gate(paid: true, cloudChief: true, hasComputer: true) == nil)
        // A Chief of this Mac: the note points at the Computer Use picker under it, with the move.
        let panel = HomeChiefProfileView(settings: Self.card())
        panel.name = { "mario" }
        panel.paid = { true }
        panel.select(.computer)
        #expect(panel.shownGate == .needsCloudChief)
        #expect(panel.gateLabel.stringValue == HomeEngineStrings.computerNeedsCloudOrMachine("mario"))
        #expect(!panel.gateButton.isHidden)
        #expect(panel.settings?.sections[.computer].isHidden == false)
        panel.paid = { false }
        #expect(panel.gateButton.title == HomeEngineStrings.computerUpgrade)
    }

    @Test func controlBarLines() {
        let take = HomeChiefComputerControlBar.line(.chief, chief: "mario")
        #expect(take == .init(status: HomeEngineStrings.computerChiefDriving("mario"), action: .takeOver))
        let mine = HomeChiefComputerControlBar.line(.init(holder: .human), chief: "mario")
        #expect(mine == .init(status: HomeEngineStrings.computerYouDrive, action: .giveBack))
        let asked = HomeChiefComputerControlBar.line(.init(holder: .human, reason: "Sign in to Gmail"), chief: "mario")
        #expect(asked == .init(status: "Sign in to Gmail", action: .giveBack))
        #expect(HomeChiefComputerControlBar.line(.init(holder: .human, reason: "  "), chief: "mario")?.status == HomeEngineStrings.computerYouDrive)
        #expect(HomeChiefComputerControlBar.line(nil, chief: "mario") == nil)
    }

    @Test func takeOverAndGiveBackChangeTheLeaseAndTheScreenTakesInputOnlyWhileThePersonDrives() async throws {
        let lease = Lease()
        let panel = HomeChiefProfileView()
        panel.name = { "mario" }
        panel.paid = { true }
        panel.cloudChief = { true }
        let feed = Feed()
        panel.computer.source = feed.source()
        panel.control = lease.source(machine: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(panel)
        defer { window.close() }
        await until { panel.computer.frames >= 1 }
        #expect(!panel.controlBar.isHidden)
        #expect(panel.controlBar.status.stringValue == HomeEngineStrings.computerChiefDriving("mario"))
        #expect(panel.controlBar.button.title == HomeEngineStrings.computerTakeOver)
        #expect(panel.computer.screen.input == nil, "the Chief drives: the screen is view only")
        await panel.controlBar.act()?.value
        #expect(lease.calls == ["take_over"])
        #expect(panel.controlBar.button.title == HomeEngineStrings.computerGiveBack("mario"))
        #expect(panel.controlBar.status.stringValue == HomeEngineStrings.computerYouDrive)
        let input = try #require(panel.computer.screen.input)
        input(.click(x: 10, y: 20, button: 1, count: 1))
        input(.type("hi"))
        await until { lease.sent.count == 2 }
        #expect(lease.sent == [.click(x: 10, y: 20, button: 1, count: 1), .type("hi")], "inputs arrive in order")
        await panel.controlBar.act()?.value
        #expect(lease.calls == ["take_over", "hand_back"])
        #expect(panel.computer.screen.input == nil)
        // A refused Take Over says so and keeps the Chief driving.
        lease.refuses = true
        await panel.controlBar.act()?.value
        #expect(panel.controlBar.status.stringValue == HomeEngineStrings.computerControlFailed("mario"))
        #expect(panel.computer.screen.input == nil)
        panel.removeFromSuperview()
        #expect(!panel.isOpen)
    }

    @Test func aCloudMachineOpensItsDesktopOnTakeOverAndTheScreenTakesNoInput() async {
        let lease = Lease()
        let bar = HomeChiefComputerControlBar()
        bar.chief = { "mario" }
        bar.source = lease.source(machine: true)
        await bar.act()?.value
        #expect(lease.calls == ["take_over", "open"])
        #expect(bar.personDrives)
    }

    @Test func screenPixelsFollowTheAspectFitFrame() {
        let view = CGSize(width: 320, height: 240)  // a 16:10 frame letterboxed top and bottom
        let image = CGSize(width: 1280, height: 800)
        #expect(HomeChiefComputerScreenView.pixel(at: CGPoint(x: 0, y: 0), in: view, image: image) == nil, "in the letterbox")
        let top = HomeChiefComputerScreenView.pixel(at: CGPoint(x: 0, y: 20), in: view, image: image)
        #expect(top?.x == 0 && top?.y == 0)
        let middle = HomeChiefComputerScreenView.pixel(at: CGPoint(x: 160, y: 120), in: view, image: image)
        #expect(middle?.x == 640 && middle?.y == 400)
        #expect(HomeChiefComputerScreenView.pixel(at: CGPoint(x: 320, y: 120), in: view, image: image) == nil)
        let click = HomeChiefComputerScreenView.press(from: (5, 6), startPoint: .zero, to: (7, 8), endPoint: CGPoint(x: 2, y: 2), button: 1, count: 2)
        #expect(click == .click(x: 5, y: 6, button: 1, count: 2))
        let drag = HomeChiefComputerScreenView.press(from: (5, 6), startPoint: .zero, to: (70, 80), endPoint: CGPoint(x: 20, y: 0), button: 1, count: 1)
        #expect(drag == .drag(fromX: 5, fromY: 6, toX: 70, toY: 80))
        let wheel = HomeChiefComputerScreenView.scrollSteps(delta: 3, carried: 0, precise: false)
        #expect(wheel.steps == 3)
        let first = HomeChiefComputerScreenView.scrollSteps(delta: -10, carried: 0, precise: true)
        #expect(first.steps == 0)
        let second = HomeChiefComputerScreenView.scrollSteps(delta: -20, carried: first.carried, precise: true)
        #expect(second.steps == -1)
    }

    @Test func keysBecomeTextOrXdotoolNames() {
        func key(_ code: UInt16, _ characters: String, _ bare: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> HomeChiefComputerInput? {
            HomeChiefComputerKeys.input(keyCode: code, characters: characters, bare: bare ?? characters, modifiers: modifiers)
        }
        #expect(key(0, "a") == .type("a"))
        #expect(key(0, "A", "a", .shift) == .type("A"))
        #expect(key(36, "\r") == .key("Return"))
        #expect(key(123, "\u{F702}", nil, .shift) == .key("shift+Left"))
        #expect(key(37, "l", "l", .command) == .key("ctrl+l"), "Command stands for Control on the computer")
        #expect(key(8, "\u{3}", "c", .control) == .key("ctrl+c"))
        #expect(key(44, "÷", "/", .option) == .key("alt+slash"))
        #expect(key(53, "\u{1B}") == .key("Escape"))
        #expect(key(99, "\u{1}") == .key("F3"))
        #expect(key(55, "") == nil, "a bare modifier sends nothing")
    }

    @MainActor final class Lease {
        var state = HomeChiefComputerControlState.chief
        var calls: [String] = []
        var sent: [HomeChiefComputerInput] = []
        var refuses = false
        private var watchers: [@MainActor () -> Void] = []

        func source(machine: Bool) -> HomeChiefComputerControlSource {
            HomeChiefComputerControlSource(
                state: { [self] in state },
                observe: { [self] change in watchers.append(change); return NSObject() },
                takeOver: { [self] in try change("take_over", to: .human) },
                handBack: { [self] in try change("hand_back", to: .chief) },
                send: machine ? nil : { [self] input in sent.append(input) },
                openInteractive: machine ? { [self] in calls.append("open") } : nil)
        }

        private func change(_ call: String, to holder: HomeChiefComputerHolder) throws {
            guard !refuses else { throw CancellationError() }
            calls.append(call)
            state = .init(holder: holder)
            for watcher in watchers { watcher() }
        }
    }

    @MainActor final class Feed {
        let image = CGContext(data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()

        func source() -> HomeChiefComputerSection.Source {
            .init(paid: { true }, chief: { "mario" }, status: { .init(used: true, computer: ("vm", "running")) }, screen: { [image] in image })
        }
    }
}

@MainActor private func until(_ condition: () -> Bool) async {
    for _ in 0..<5000 where !condition() { await Task.yield() }
    #expect(condition())
}
