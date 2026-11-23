import Foundation
import Testing

/// Detector for Leo's 2026-11-23 request: "why, if ive set my built in keyboard to not have
/// noise, do those buttons have the haptic feedback noise? dont do that. ive turned off all
/// haptics already, so dont inject haptic noise when i havent asked for it. ever."
/// Every app-owned haptic emission must pass through its setting and Low Power Mode gate.
@Suite struct NoUngatedHapticsTests {
    private static let banned = [
        "UIImpactFeedbackGenerator(",
        "UISelectionFeedbackGenerator(",
        "UINotificationFeedbackGenerator(",
        ".sensoryFeedback(",
        "AudioServicesPlaySystemSound",
        "AudioServicesPlayAlertSound",
        "CHHapticEngine(",
    ]

    private static let allowedFileNames: Set<String> = [
        "Theme.swift", "ConversationHaptics.swift", "ScreenKitHaptics.swift",
    ]

    private static var kitRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var sourceRoots: [URL] {
        let repoRoot = kitRoot.deletingLastPathComponent().deletingLastPathComponent()
        return [
            kitRoot.appendingPathComponent("Sources"),
            repoRoot.appendingPathComponent("Packages/iOS/CmuxConversation/Sources"),
            repoRoot.appendingPathComponent("Packages/Shared/CmuxScreenKit/Sources"),
        ]
    }

    private static func swiftFiles(in root: URL) throws -> [URL] {
        try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
    }

    private static func isAllowed(_ file: URL) -> Bool {
        if allowedFileNames.contains(file.lastPathComponent) { return true }
        // TerminalKeyBar.swift and Joystick.swift remain in the owner-controlled KeyBar area.
        return file.pathComponents.contains("KeyBar")
    }

    @Test func noRawHapticEmissionOutsideGates() throws {
        var hits: [String] = []
        for root in sourceRoots {
            for file in try Self.swiftFiles(in: root) where !Self.isAllowed(file) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let sourceLine = String(line)
                    let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("/*"), !trimmed.hasPrefix("*") else { continue }
                    for banned in Self.banned where sourceLine.contains(banned) {
                        hits.append("\(file.path):\(number + 1): \(banned)")
                    }
                }
            }
        }
        #expect(hits.isEmpty, "raw haptic call must route through the gate:\n\(hits.joined(separator: "\n"))")
    }
}
