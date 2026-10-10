import Foundation
import Testing
@testable import CmuxNextRemoteView

struct RemoteDesktopSettingsTests {
    /// `| `key` | `default` | ... |` rows of the module README.
    private static func readmeDefaults() throws -> [String: String] {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextRemoteView/README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        var rows: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| `remoteDesktop.") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            rows[cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`"))] =
                cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        return rows
    }

    @Test func defaultsMatchTheReadmeTable() throws {
        let documented = try Self.readmeDefaults()
        let actual = RemoteDesktopSettings().documentedValues
        #expect(Set(documented.keys) == Set(RemoteDesktopSettings.documentedKeys))
        #expect(documented == actual)
    }

    @Test func readsDottedAndNestedKeys() {
        let flat = RemoteDesktopSettings(json: [
            "remoteDesktop.keyboard.mode": "text", "remoteDesktop.interactiveMaxRttMs": 120,
            "remoteDesktop.maxFps": 30, "remoteDesktop.showPathBadge": false,
        ])
        #expect(flat.keyboardMode == .text)
        #expect(flat.interactiveMaxRttMs == 120)
        #expect(flat.maxFps == 30)
        #expect(!flat.showPathBadge)
        let nested = RemoteDesktopSettings(json: [
            "remoteDesktop": ["keyboard": ["sendSystemShortcuts": true], "quality": "sharpText", "maxBitrateMbps": 12.5],
        ])
        #expect(nested.sendSystemShortcuts)
        #expect(nested.quality == .sharpText)
        #expect(nested.maxBitrateMbps == 12.5)
    }

    @Test func invalidValuesKeepTheirDefaults() {
        let settings = RemoteDesktopSettings(json: [
            "remoteDesktop.keyboard.mode": "loud", "remoteDesktop.interactiveMaxRttMs": "fast",
            "remoteDesktop.audio": 1, "remoteDesktop.maxFps": 0, "remoteDesktop.codec": "av2",
        ])
        #expect(settings == RemoteDesktopSettings())
        #expect(RemoteDesktopSettings(json: ["remoteDesktop.maxFps": "auto"]).maxFps == nil)
    }
}
