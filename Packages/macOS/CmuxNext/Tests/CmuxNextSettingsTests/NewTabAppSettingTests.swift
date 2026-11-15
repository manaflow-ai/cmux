import CmuxNextSettings
import Foundation
import Testing

/// `tabs.newTabApp`: the extension that draws the whole New Tab page. Unset by default (cmux's own
/// page), an app id when set, and a value that is no app id is refused on every surface.
@Suite struct NewTabAppSettingTests {
    @Test func unsetByDefaultAndReadAsAnAppID() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabApp"]))
        #expect(descriptor.defaultValue == nil, "cmux's own page stays the default")
        #expect(SettingsSchema.agentSettableKeys.contains("tabs.newTabApp"))

        let unset = try JSONValue.parse(Data(#"{"tabs":{}}"#.utf8))
        #expect(NewTabAppSetting.app(in: unset) == nil)
        let set = try JSONValue.parse(Data(#"{"tabs":{"newTabApp":"local/showcase-newtab"}}"#.utf8))
        #expect(NewTabAppSetting.app(in: set) == "local/showcase-newtab")
    }

    @Test func refusesWhatIsNoAppID() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["tabs", "newTabApp"]))
        #expect(descriptor.accepts(.string("manaflow-ai/launcher")))
        for bad in ["", "launcher", "a/b/c", "/b", "a/", "a b/c"] {
            #expect(!descriptor.accepts(.string(bad)), "\(bad)")
        }
        #expect(!descriptor.accepts(.bool(true)))
    }
}
