import Foundation
import Testing

/// Asking a view's layer for an action (`layer.action(forKey:)`) inside a
/// UIView animation block runs UIView's `action(for:forKey:)`, which
/// registers an animation with the block that is never added to a layer.
/// On iOS 26 the block's completion then never fires. A bubble laid out in
/// a rotation did this: the rotation never finished, so turning the phone
/// back to portrait left the window landscape-sized (874 x 402 pt, the
/// rest black) until relaunch.
///
/// The iOS views can't run under `swift test`, so this reads their sources.
@Suite struct LayerActionQueryTests {
    @Test func iOSViewsNeverAskALayerForItsAction() throws {
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
            for (index, line) in lines.enumerated() where line.contains(".action(forKey:") {
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "layer.action(forKey:) inside an animation leaves its completion pending: \(offenders)")
    }
}
