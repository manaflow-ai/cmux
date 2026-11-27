import CmuxRemoteSession
import Testing

@Suite struct RemoteTmuxKeyNameTests {
    @Test func normalizesNamedKeyAliasesAndModifierOrder() {
        let cases = [
            ("end", "End"),
            ("ctrl-del", "C-DC"),
            ("shift-ctrl-arrow_up", "C-S-Up"),
            ("option-page_down", "M-NPage"),
            ("ctrl+alt+f12", "C-M-F12"),
        ]

        for (rawName, expected) in cases {
            #expect(RemoteTmuxKeyName(rawName: rawName)?.value == expected)
        }
    }

    @Test func rejectsUnknownNamesAndUnsafeText() {
        #expect(RemoteTmuxKeyName(rawName: "not-a-key") == nil)
        #expect(RemoteTmuxKeyName(rawName: "End; kill-server") == nil)
        #expect(RemoteTmuxKeyName(rawName: "command-End") == nil)
        #expect(RemoteTmuxKeyName(rawName: "") == nil)
    }
}
