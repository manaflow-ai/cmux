import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextApp

/// The app-wide tunable catalog and where Debug Settings keeps overrides.
@MainActor
@Suite struct TunableCatalogAppTests {
    @Test func everyModuleContributesUniqueKeysWithValidDefaults() {
        let all = TunableCatalog.all
        #expect(Set(all.map(\.key)).count == all.count)
        #expect(all.count >= 140)
        for descriptor in all {
            #expect(descriptor.clamp(descriptor.defaultValue) == descriptor.defaultValue, "\(descriptor.key) default out of range")
        }
        let sections = Set(all.map(\.section.id))
        for section in [TunableSection.dropOverlay, .tabDrag, .tabs, .panes, .sidebar, .palette, .shape, .springs, .fades, .hover, .glass, .focus] {
            #expect(sections.contains(section.id), "\(section.title) has no tunables")
        }
    }

    @Test func overrideFileFollowsTagOrChannelAndTheScratchOverride() {
        let home = URL(fileURLWithPath: "/Users/test")
        let tagged = DebugSettingsService.fileURL(environment: [:], tag: "nxtun", bundleID: "com.cmuxterm.app.debug.nxtun", home: home)
        #expect(tagged.path == "/Users/test/Library/Application Support/cmux/nxtun/debug-tunables.json")
        let nightly = DebugSettingsService.fileURL(environment: [:], tag: nil, bundleID: "com.cmuxterm.app.nightly", home: home)
        #expect(nightly.path == "/Users/test/Library/Application Support/cmux/nightly/debug-tunables.json")
        let dev = DebugSettingsService.fileURL(environment: [:], tag: nil, bundleID: "com.cmuxterm.app.debug", home: home)
        #expect(dev.path.hasSuffix("cmux/dev/debug-tunables.json"))
        let scratch = DebugSettingsService.fileURL(environment: ["CMUX_NEXT_DEBUG_TUNABLES_FILE": "/tmp/t/tunables.json"], tag: "x",
                                                   bundleID: nil, home: home)
        #expect(scratch.path == "/tmp/t/tunables.json")
    }
}
