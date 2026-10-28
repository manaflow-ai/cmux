import AppKit
@testable import CmuxNextActions
import CmuxNextChiefPetWiring
import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// Leo 2026-10-21: "the nine avatars, we need to be able to just swap them out, just how ChatGPT
/// does." The Chief Settings popover (the "Chief ›" pill on Home, and the pet's Chief Pet
/// Settings…) shows all nine characters at once, the current one checked; one click swaps the
/// pet's character (`home.chiefPetMascot`) and leaves Show Chief Pet (`home.chiefPetEnabled`) alone.
@MainActor @Suite(.serialized) struct ChiefPetPopoverPickerTests {
    struct Harness {
        let popover: HomeChiefSettingsView
        let rows: ChiefPetSettingsRows
        let settings: SettingsController
        let url: URL

        /// The `home` object as cmux.json holds it now.
        func savedHome() -> [String: Any]? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return root["home"] as? [String: Any]
        }

        func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        /// Waits for `condition` up to a deadline: the settings write and reload run on other tasks.
        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// The popover's controls a person picks a character with: one per character, by its name.
        func characters() -> [NSButton] {
            let names = Set(ChiefPetPopoverPickerTests.names())
            return ChiefPetPopoverPickerTests.descendants(of: popover).compactMap { $0 as? NSButton }
                .filter { $0.isAccessibilityElement() && names.contains($0.accessibilityLabel() ?? "") }
        }

        func checked() -> [String] { characters().filter { $0.state == .on }.compactMap { $0.accessibilityLabel() } }
    }

    /// The characters' names as the Settings page shows them, in its order.
    static func names() -> [String] {
        guard case .choice(let choices)? = SettingsSchema.descriptor(for: HomeChiefPetSetting.mascotPath)?.kind else { return [] }
        return choices.map(\.title)
    }

    static func name(of id: String) -> String? {
        guard case .choice(let choices)? = SettingsSchema.descriptor(for: HomeChiefPetSetting.mascotPath)?.kind else { return nil }
        return choices.first { $0.value == id }?.title
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    func make(_ json: String, node: VisibilityNode = shownNode()) async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-pet-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let home = directory.appending(path: "brain")
        let popover = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), lanes: BackgroundWork(label: "test.chief-engine"), connection: { nil }))
        let rows = ChiefPetSettingsRows(settings: { settings }, homes: ChiefPetHomes(),
                                        picks: ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief))
        rows.install(in: popover, node: node, mainWork: linklessMainWork(), addRow: { popover.addAppearanceRow($0, control: $1) },
                     open: { false })
        return Harness(popover: popover, rows: rows, settings: settings, url: url)
    }

    @Test func thePopoverOffersAllNineWithTheCurrentOneChecked() async throws {
        let h = try await make(#"{"home":{"chiefPetMascot":"moon"}}"#)
        defer { h.tearDown() }
        let moon = try #require(Self.name(of: "moon"))
        await h.until { h.checked() == [moon] }
        #expect(Self.names().count == 9)
        #expect(h.characters().compactMap { $0.accessibilityLabel() } == Self.names())
        #expect(h.characters().allSatisfy { $0.image != nil }, "each character shows its picture")
        #expect(h.checked() == [moon])
    }

    @Test func oneClickSwapsTheCharacterAndLeavesThePetOff() async throws {
        let h = try await make("{}")
        defer { h.tearDown() }
        let orb = try #require(Self.name(of: "orb"))
        let fox = try #require(Self.name(of: "fox"))
        await h.until { h.checked() == [orb] }
        #expect(h.checked() == [orb], "orb is the default")
        let button = try #require(h.characters().first { $0.accessibilityLabel() == fox })
        button.performClick(nil)
        await h.until { h.settings.snapshot.homeChiefPetMascot == "fox" && h.checked() == [fox] }
        #expect(h.settings.snapshot.homeChiefPetMascot == "fox")
        #expect(h.savedHome()?["chiefPetMascot"] as? String == "fox")
        #expect(h.checked() == [fox])
        // Choosing a character never turns the pet on.
        #expect(h.savedHome()?["chiefPetEnabled"] == nil)
        #expect(!h.settings.snapshot.homeChiefPetEnabled)
    }

    /// p06 sweep (group 333): the rows follow the settings with a VisibleObservation on the Home view's
    /// node, not a main-inherited observation task: a hidden Home shows what was current when the rows
    /// were made and reads nothing while hidden; shown again, it reads once and shows the new character.
    @Test func aHiddenHomeShowsTheNewCharacterOnceShown() async throws {
        let node = VisibilityNode(root: "test.hiddenHome", own: .hidden)
        let h = try await make("{}", node: node)
        defer { h.tearDown() }
        let orb = try #require(Self.name(of: "orb"))
        let fox = try #require(Self.name(of: "fox"))
        #expect(h.checked() == [orb], "the rows show the current character when made, hidden or not")
        try await h.settings.setSetting(at: HomeChiefPetSetting.mascotPath, to: .string("fox"), by: .user)
        await h.until { h.settings.snapshot.homeChiefPetMascot == "fox" }
        #expect(h.settings.snapshot.homeChiefPetMascot == "fox")
        #expect(h.checked() == [orb], "a hidden Home reads nothing")
        node.set(.visible)
        await h.until { h.checked() == [fox] }
        #expect(h.checked() == [fox], "shown, it reads once and shows the new character")
    }

    /// Chief Pet Settings… never opens a Home whose window is ordered out: its node reads occluded (no
    /// notice marks an ordered-out window hidden), and the raise would bring that window back.
    @Test func anOrderedOutWindowsHomeIsNotOpened() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-pet-ordered-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appending(path: "brain")
        let popover = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), lanes: BackgroundWork(label: "test.chief-engine"), connection: { nil }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = popover
        let homes = ChiefPetHomes()
        let rows = ChiefPetSettingsRows(settings: { nil }, homes: homes,
                                        picks: ChiefMascotPicks(defaults: nil, defaultChief: HomeChiefAvatars.defaultChief))
        var opened = 0
        rows.install(in: popover, node: shownNode(), mainWork: linklessMainWork(), addRow: { popover.addAppearanceRow($0, control: $1) },
                     open: { opened += 1; return true })
        #expect(!window.isVisible)
        // The rows stay installed (ChiefPetHomes holds them weakly) through the open.
        withExtendedLifetime(rows) {
            #expect(!homes.open(noActivate: true))
        }
        #expect(opened == 0, "an ordered-out window's popover is never opened")
        #expect(!window.isVisible, "the window stays ordered out")
    }
}
