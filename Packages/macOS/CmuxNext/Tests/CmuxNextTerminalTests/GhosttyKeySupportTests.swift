import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// The keys cmux reports as not applied (R92 diagnostics) are real Ghostty
/// keys, so a renamed or removed key cannot hide in the table, and only a
/// superseded key names its cmux replacement.
@MainActor @Suite(.serialized) struct GhosttyKeySupportTests {
    /// libghostty needs `ghostty_init` (the shared runtime) before configs.
    init() { _ = GhosttyRuntime.shared }

    @Test func everyUnsupportedKeyIsAGhosttyKeyAndOnlySupersededOnesNameAReplacement() {
        let ghosttyKeys = Set((0..<ghostty_config_key_count()).compactMap { ghostty_config_key_name($0).map { String(cString: $0) } })
        #expect(ghosttyKeys.count > 100)
        #expect(!GhosttyKeySupport.unsupported.isEmpty)
        for (key, support) in GhosttyKeySupport.unsupported {
            #expect(ghosttyKeys.contains(key), "\(key) is a Ghostty key")
            #expect((support.replacement != nil) == (support.reason == .superseded), "\(key)")
        }
        #expect(GhosttyKeySupport.unsupported["clipboard-read"] == nil, "clipboard-read applies (the broker)")
        #expect(GhosttyKeySupport.unsupported["bell-features"] == nil, "the bell keys apply")
        #expect(GhosttyKeySupport.unsupported["window-decoration"] == GhosttyUnsupported(.superseded, replacement: "window.titlebar"))
    }
}
