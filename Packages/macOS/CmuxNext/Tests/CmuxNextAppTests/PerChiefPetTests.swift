import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextChiefPetWiring
import CmuxNextDesign
import CmuxNextFloating
import CmuxNextWakeups
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-21: "the chief avatar switching the pet thing it needs to apply per chief". Picking a
/// pet character in one Chief's settings changes that Chief only: each Chief keeps its own across a
/// relaunch, a new Chief starts on the default character, and the default Chief keeps the character
/// `home.chiefPetMascot` already names (the pet's, the one the Settings page shows).
@MainActor @Suite(.serialized) struct PerChiefPetTests {
    static let main = HomeChiefAvatars.defaultChief
    static let scout = "agent_scout01"

    /// How many times the rows asked the header to redraw (`onMascot`).
    @MainActor final class Redraws {
        var count = 0
    }

    /// One Chief's settings popover with the pet rows installed, as HomeHostView builds it.
    struct Popover {
        let view: HomeChiefSettingsView
        let rows: ChiefPetSettingsRows
        let redraws: Redraws

        /// The popover's character buttons, by the names the Settings page shows.
        func characters() -> [NSButton] {
            let names = Set(ChiefPetPopoverPickerTests.names())
            return ChiefPetPopoverPickerTests.descendants(of: view).compactMap { $0 as? NSButton }
                .filter { $0.isAccessibilityElement() && names.contains($0.accessibilityLabel() ?? "") }
        }

        func checked() -> [String] { characters().filter { $0.state == .on }.compactMap { $0.accessibilityLabel() } }

        func pick(_ id: String) throws {
            let name = try #require(ChiefPetPopoverPickerTests.name(of: id))
            try #require(characters().first { $0.accessibilityLabel() == name }).performClick(nil)
        }
    }

    struct Harness {
        let settings: SettingsController
        let url: URL
        let suite: String
        let defaults: UserDefaults

        func savedHome() -> [String: Any]? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return root["home"] as? [String: Any]
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        /// The app's per-Chief picks as a launch reads them from its defaults.
        func picks() -> ChiefMascotPicks { ChiefMascotPicks(defaults: defaults, defaultChief: PerChiefPetTests.main) }

        func popover(chief: String, picks: ChiefMascotPicks) async -> Popover {
            let home = url.deletingLastPathComponent().appending(path: "brain-\(chief)")
            let view = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), lanes: BackgroundWork(label: "test.chief-engine"), connection: { nil }))
            let rows = ChiefPetSettingsRows(settings: { settings }, homes: ChiefPetHomes(), picks: picks)
            let redraws = Redraws()
            rows.onMascot = { redraws.count += 1 }
            // HomeHostView's order: the rows are installed and show the default Chief's character,
            // then the conversation's Chief is known.
            rows.install(in: view, node: shownNode(), mainWork: linklessMainWork(), addRow: { view.addAppearanceRow($0, control: $1) },
                         open: { false })
            let popover = Popover(view: view, rows: rows, redraws: redraws)
            await until { redraws.count > 0 }
            rows.chief = chief
            return popover
        }
    }

    func make(_ json: String) async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-per-chief-pet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let suite = "cnc-per-chief-pet-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return Harness(settings: settings, url: url, suite: suite, defaults: defaults)
    }

    @Test func twoChiefsKeepTheirOwnPetsAcrossARelaunch() async throws {
        // Leo's pick from before: the default Chief's (and the pet's) character.
        let h = try await make(#"{"home":{"chiefPetMascot":"fox"}}"#)
        defer { h.tearDown() }
        let picks = h.picks()
        let main = await h.popover(chief: Self.main, picks: picks)
        let scout = await h.popover(chief: Self.scout, picks: picks)
        let fox = try #require(ChiefPetPopoverPickerTests.name(of: "fox"))
        let orb = try #require(ChiefPetPopoverPickerTests.name(of: "orb"))
        let moon = try #require(ChiefPetPopoverPickerTests.name(of: "moon"))
        let machine = try #require(ChiefPetPopoverPickerTests.name(of: "machine"))
        await h.until { main.checked() == [fox] && scout.checked() == [orb] }
        #expect(main.checked() == [fox], "the default Chief keeps the character it wore")
        #expect(scout.checked() == [orb], "another Chief starts on the default character")

        // Scout picks the character the default Chief wears: the header redraws in Scout's.
        let redraws = scout.redraws.count
        try scout.pick("fox")
        await h.until { scout.redraws.count > redraws }
        #expect(scout.redraws.count > redraws, "Scout's header wears its new character")
        #expect(scout.checked() == [fox])
        #expect(picks.mascot(of: Self.scout, in: h.settings.snapshot) == "fox")

        // Scout's pick changes Scout only.
        try scout.pick("moon")
        await h.until { scout.checked() == [moon] }
        #expect(scout.checked() == [moon])
        #expect(main.checked() == [fox])
        #expect(picks.mascot(of: Self.scout, in: h.settings.snapshot) == "moon")
        #expect(picks.mascot(of: Self.main, in: h.settings.snapshot) == "fox")
        #expect(h.savedHome()?["chiefPetMascot"] as? String == "fox", "Scout's pick never writes the pet's character")

        // The default Chief's pick changes it (and the pet) only: Scout keeps moon.
        try main.pick("machine")
        await h.until { h.settings.snapshot.homeChiefPetMascot == "machine" && main.checked() == [machine] }
        #expect(main.checked() == [machine])
        #expect(h.savedHome()?["chiefPetMascot"] as? String == "machine")
        #expect(scout.checked() == [moon])

        // A relaunch reads each Chief's pick back; a new Chief gets the default.
        let relaunched = h.picks()
        #expect(relaunched.mascot(of: Self.scout, in: h.settings.snapshot) == "moon")
        #expect(relaunched.mascot(of: Self.main, in: h.settings.snapshot) == "machine")
        #expect(relaunched.mascot(of: "agent_new02", in: h.settings.snapshot) == HomeChiefPetSetting.defaultMascot)
        let reopened = await h.popover(chief: Self.scout, picks: relaunched)
        await h.until { reopened.checked() == [moon] }
        #expect(reopened.checked() == [moon])
    }

    /// The Home list, a Chief's header and a group's bubbles draw each Chief with its own
    /// character when it has no picture of its own; a picture of its own still wins.
    @Test func eachChiefsFaceIsItsOwnCharacter() async throws {
        let h = try await make(#"{"home":{"chiefPetMascot":"fox"}}"#)
        defer { h.tearDown() }
        let picks = h.picks()
        picks.remember("moon", for: Self.scout)
        let picture: (String) -> URL? = { ChiefPetSettingsRows.avatarURL(of: picks.mascot(of: $0, in: h.settings.snapshot)) }
        let faces = HomeService.chiefFaces(chiefs: [Self.main, Self.scout, "agent_new02"], own: [:], picture: picture)
        #expect(faces[Self.main] == ChiefPetMascot.fox.avatarURL.map(HomeChiefAvatar.picture))
        #expect(faces[Self.scout] == ChiefPetMascot.moon.avatarURL.map(HomeChiefAvatar.picture))
        #expect(faces["agent_new02"] == ChiefPetMascot.orb.avatarURL.map(HomeChiefAvatar.picture))
        #expect(faces[Self.main] != faces[Self.scout])
        let own = HomeService.chiefFaces(chiefs: [Self.main, Self.scout], own: [Self.scout: .text("SC")], picture: picture)
        #expect(own[Self.scout] == .text("SC"))
        #expect(own[Self.main] == faces[Self.main])
    }
}
