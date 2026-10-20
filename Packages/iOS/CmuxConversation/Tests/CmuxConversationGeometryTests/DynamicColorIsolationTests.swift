import Foundation
import Testing

/// A `UIColor { traits in ... }` provider written inside main-actor code
/// (a view's init, say) inherits main-actor isolation. The crash reporter's
/// screenshot masking resolves colors on a background queue, and Swift's
/// isolation check then traps: the conversation crashed on open on a real
/// iPhone (iOS 26.4.2) in `ConversationHeaderView.init`'s unread-pill color.
/// Providers go through `UIColor.resolving`, whose `@Sendable` parameter
/// keeps them nonisolated.
///
/// The iOS views can't run under `swift test`, so this reads their sources.
@Suite struct DynamicColorIsolationTests {
    @Test func dynamicColorsUseTheSendableProvider() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxConversationUI")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let bare = line.contains("UIColor {") && !line.contains("-> UIColor {") && !line.contains("extension UIColor {")
                if bare || line.contains("UIColor(dynamicProvider:") && !line.contains("provider)") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "dynamic color providers must use UIColor.resolving: \(offenders)")
    }
}
