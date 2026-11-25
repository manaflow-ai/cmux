import CoreGraphics
import Foundation
@testable import CmuxNextUpdater
import Testing

/// The relaunch afterimage's files: the plan the osascript side reads, the new copy's `painted` answer, and a
/// leftover folder from an afterimage that is gone.
@Suite(.serialized) struct RelaunchAfterimageTests {
    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "RelaunchAfterimageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        return try #require(context.makeImage())
    }

    @Test func planNamesEveryPictureBackToFront() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: RelaunchAfterimage.folderName)
        let pictures = [RelaunchAfterimage.Picture(number: 11, frame: CGRect(x: 10, y: 20, width: 300, height: 200), image: try Self.image()),
                        RelaunchAfterimage.Picture(number: 12, frame: CGRect(x: 40, y: 50, width: 640, height: 480), image: try Self.image())]
        #expect(RelaunchAfterimage.write(pictures, activates: true, status: "Restarting…", to: folder))
        let plan = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "plan.json"))) as? [String: Any])
        #expect(plan["activates"] as? Bool == true)
        #expect(plan["status"] as? String == "Restarting…") // the line over the front picture, so the picture never reads as a frozen window
        #expect(plan["deadlineMs"] as? Int == 8000)
        let windows = try #require(plan["windows"] as? [[String: Any]])
        #expect(windows.map { $0["above"] as? Int } == [11, 12])
        #expect(windows.map { $0["w"] as? Double } == [300, 640])
        for window in windows {
            let name = try #require(window["image"] as? String)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: name).path))
        }
    }

    @Test func newCopyAnswersAFreshPlanAndRemovesALeftover() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: RelaunchAfterimage.folderName)
        // No afterimage: nothing is written.
        RelaunchAfterimage.newCopyDrew(stateDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(RelaunchAfterimage.write([], activates: false, to: folder))
        RelaunchAfterimage.newCopyDrew(stateDirectory: root)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "painted").path))
        // A plan older than a relaunch takes: its afterimage is gone, so the folder goes.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: folder.appending(path: "plan.json").path)
        RelaunchAfterimage.newCopyDrew(stateDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func runsTheBundledScriptUnderOsascript() throws {
        let script = try #require(RelaunchAfterimage.bundledScript)
        let args = RelaunchAfterimage.arguments(script: script, folder: URL(fileURLWithPath: "/tmp/x"))
        #expect(args == ["/usr/bin/osascript", "-l", "JavaScript", script.path, "/tmp/x"])
    }
}
