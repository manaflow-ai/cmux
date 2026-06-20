import Foundation
import Testing

@testable import CmuxCommandPalette

@Suite struct CommandPaletteHashedCommandIDTests {
    /// The legacy `ContentView` derivation, reproduced here so the test fails if
    /// the package's hashing ever diverges from the frozen wire format.
    private func legacyHashedID(prefix: String, key: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return prefix + String(hash, radix: 16)
    }

    @Test func matchesLegacyDerivationForEveryDomain() {
        let keys = ["", "Red", "Crimson", "default", "com.example.provider", "issue:42", "a/b/c", "日本語"]
        let cases: [(CommandPaletteHashedCommandID.Domain, String)] = [
            (.cmuxConfigIssue, "palette.cmuxConfig.issue."),
            (.workspaceColor, "palette.workspaceColor."),
            (.extensionSidebar, "palette.extensionSidebar."),
        ]
        for (domain, prefix) in cases {
            #expect(domain.prefix == prefix)
            for key in keys {
                #expect(
                    CommandPaletteHashedCommandID(domain: domain, key: key).value
                        == legacyHashedID(prefix: prefix, key: key)
                )
            }
        }
    }

    @Test func goldenValuesAreStable() {
        // FNV-1a of the empty string is the offset basis, hex 14650fb0739d0383.
        #expect(
            CommandPaletteHashedCommandID(domain: .workspaceColor, key: "").value
                == "palette.workspaceColor.14650fb0739d0383"
        )
    }

    @Test func differentDomainsNeverCollideForSameKey() {
        let key = "Blue"
        let ids = Set(
            CommandPaletteHashedCommandID.Domain.allCases.map {
                CommandPaletteHashedCommandID(domain: $0, key: key).value
            }
        )
        #expect(ids.count == CommandPaletteHashedCommandID.Domain.allCases.count)
    }
}
