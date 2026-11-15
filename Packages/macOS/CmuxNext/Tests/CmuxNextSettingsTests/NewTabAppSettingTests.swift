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
        for good in ["manaflow-ai/launcher", "local/web-pane", "0x/a-b"] {
            #expect(descriptor.accepts(.string(good)), "\(good)")
        }
        // The manifest id pattern (cmux-app.schema.json `properties.id.pattern`): lowercase only.
        for bad in ["", "launcher", "a/b/c", "/b", "a/", "a b/c", "Foo/Bar", "local/Web", "-a/b"] {
            #expect(!descriptor.accepts(.string(bad)), "\(bad)")
        }
        #expect(!descriptor.accepts(.bool(true)))
    }
}
