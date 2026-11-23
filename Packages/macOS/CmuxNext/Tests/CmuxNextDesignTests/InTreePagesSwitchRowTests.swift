@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Debug Settings › Chromium In-Tree Pages › "Pages in the window's view tree" told a lie in a build tagged
/// `in-tree-pages…` (user, 34f21f2f): the switch showed Off (Default: Off) while the build tag had turned the mode on.
/// The row's default is the build's own (the tag, the environment), so the switch shows the state with no file
/// override, and an override of the file still differs from it (the dot, Reset).
@MainActor @Suite(.serialized) struct InTreePagesSwitchRowTests {
    @Test func aTagDefaultBuildShowsTheSwitchOn() {
        defer { InTreePages.shared.setForTesting(requested: false) }
        InTreePages.shared.setForTesting(requested: nil)
        InTreePages.shared.latch(fileOverride: nil, tag: "in-tree-pages-fix", environment: [:])
        #expect(InTreePages.shared.isRequested)
        #expect(InTreePages.tunable.descriptor.defaultValue == .bool(true), "a tag-default build: the switch's default is On")
    }

    @Test func anUntaggedBuildShowsTheSwitchOff() {
        defer { InTreePages.shared.setForTesting(requested: false) }
        InTreePages.shared.setForTesting(requested: nil)
        InTreePages.shared.latch(fileOverride: nil, tag: "other", environment: [:])
        #expect(InTreePages.tunable.descriptor.defaultValue == .bool(false))
    }

    /// The file's Off still turns a tag-default build off, and its default stays the build's On.
    @Test func theFileOverrideStillDecidesAndDiffersFromTheBuildDefault() {
        defer { InTreePages.shared.setForTesting(requested: false) }
        InTreePages.shared.setForTesting(requested: nil)
        InTreePages.shared.latch(fileOverride: false, tag: "in-tree-pages-fix", environment: [:])
        #expect(!InTreePages.shared.isRequested)
        #expect(InTreePages.shared.source == "file")
        #expect(InTreePages.tunable.descriptor.defaultValue == .bool(true))
    }

    /// The environment decides before the file and the tag: the row's default follows it.
    @Test func theEnvironmentDecidesTheDefault() {
        defer { InTreePages.shared.setForTesting(requested: false) }
        InTreePages.shared.setForTesting(requested: nil)
        InTreePages.shared.latch(fileOverride: true, tag: "in-tree-pages-fix", environment: [InTreePages.environmentKey: "0"])
        #expect(!InTreePages.shared.isRequested)
        #expect(InTreePages.shared.source == "environment")
        #expect(InTreePages.tunable.descriptor.defaultValue == .bool(false))
    }
}
