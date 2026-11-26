import Testing
@testable import CmuxMobileBrowserStream

/// The phone's Mac display keys read like hostd's (`surface.rs` `mac_display_of`): one key per display.
@Suite struct MacDisplayTests {
    @Test func keysNameOneDisplayOnce() {
        #expect(StreamedBrowserDirectory.macDisplayTab() == "d~0")
        #expect(StreamedBrowserDirectory.macDisplayTab(display: 69_734_272) == "d~69734272")
        #expect(StreamedBrowserDirectory.macDisplay(ofTab: "d~0") == 0)
        #expect(StreamedBrowserDirectory.macDisplay(ofTab: "d~4294967295") == UInt32.max)
        for bad in ["", "d", "d~", "d~01", "d~-1", "d~+1", "d~ 1", "d~1 ", "d~4294967296", "D~1", "d1", "s1", "c~m~t", "d~١"] {
            #expect(StreamedBrowserDirectory.macDisplay(ofTab: bad) == nil, "\(bad)")
        }
        for display: UInt32 in [0, 1, 69_734_272, .max] {
            #expect(StreamedBrowserDirectory.macDisplay(ofTab: StreamedBrowserDirectory.macDisplayTab(display: display)) == display)
        }
        #expect(StreamedBrowserDirectory.macDisplayCapability == "mac-display-v1")
    }
}
