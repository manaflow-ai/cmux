import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The native transcript meets the Chief thread's structure spec (tests/ui-structure/chief-thread.json,
/// checked by tests/ui-structure/thread_structure.py), read the way an accessibility client reads the
/// app: the transcript's AXList "Messages" and its 'message' elements (TranscriptAccess.swift), their
/// frames and senders. Leo, 2026-11-10, after a nightly drew the Chief panel as an avatar column beside
/// grey cards: "Where's the spec for that? Where's the iMessage".
///
/// Each case is one gallery variant of the Chief thread (a Chief panel width, or a conversation tab):
/// its snapshot and still go to CHIEF_THREAD_GALLERY_DIR when set (the workflow keeps them), and the
/// checker must pass it.
@Suite(.serialized) @MainActor struct ChiefThreadStructureTests {
    struct Variant: CustomTestStringConvertible, Sendable {
        let name: String
        let surface: String
        let width: CGFloat
        let height: CGFloat
        var testDescription: String { name }
    }

    /// The gallery: the narrowest Chief panel, its default, the wide panel of Leo's 2026-11-10 screenshot,
    /// and a conversation tab.
    static let variants = [
        Variant(name: "chief-panel-narrow", surface: "chief-panel", width: 380, height: 760),
        Variant(name: "chief-panel-default", surface: "chief-panel", width: 520, height: 860),
        Variant(name: "chief-panel-wide", surface: "chief-panel", width: 1035, height: 1320),
        Variant(name: "conversation-tab", surface: "conversation-tab", width: 820, height: 900),
    ]

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test(arguments: variants)
    func theThreadMeetsTheSpec(_ variant: Variant) async throws {
        let rig = try await HomeChatRig(history: 40, width: variant.width, height: variant.height)
        defer { rig.stop() }
        for _ in 0..<6 { rig.frame() }
        await rig.send("\(HomeChatRig.tag) a line of mine, long enough to wrap once the panel is narrow enough to make it wrap")
        for _ in 0..<6 { rig.frame() }

        let snapshot = try Self.snapshot(rig, surface: variant.surface, source: "MessagesLab native transcript, \(variant.name)")
        let messages = try #require(snapshot["messages"] as? [[String: Any]])
        #expect(messages.count >= 3, "the transcript's accessibility list shows its messages (\(messages.count))")
        #expect(messages.contains { $0["mine"] as? Bool == true }, "my line is in the list, as You")

        let dir = ProcessInfo.processInfo.environment["CHIEF_THREAD_GALLERY_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("chief-thread-gallery-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(variant.name).json")
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        Self.still(rig.view, to: dir.appendingPathComponent("\(variant.name).png"))

        let (status, output) = try Self.check(file)
        #expect(status == 0, "thread_structure.py check \(file.path):\n\(output)")
    }

    /// The thread as the accessibility tree has it, in the snapshot shape thread_structure.py reads
    /// (points, top-left origin).
    static func snapshot(_ rig: HomeChatRig, surface: String, source: String) throws -> [String: Any] {
        let window = rig.window
        let height = try #require(window.contentView).bounds.height
        func topLeft(_ screen: CGRect) -> [Double] {
            let r = window.convertFromScreen(screen)
            return [r.minX, height - r.maxY, r.width, r.height].map { Double($0) }
        }
        func inWindow(_ view: NSView) -> [Double] {
            let r = view.convert(view.bounds, to: nil)
            return [r.minX, height - r.maxY, r.width, r.height].map { Double($0) }
        }
        let host = rig.view.controller.host
        let elements = rig.view.controller.accessibilityElements(parent: host)
        let you = NativeStrings.you
        let messages: [[String: Any]] = elements.map { e in
            let text = (e.accessibilityValue() as? String) ?? ""
            let sender = e.accessibilityTitle() ?? ""
            return [
                "frame": topLeft(e.accessibilityFrame()),
                "mine": sender == you,
                "sender": sender == you ? "You" : sender,
                "text": text,
                "kind": text.hasPrefix(String(format: NativeStrings.attachmentFormat, "")) ? "attachment" : "text",
                "tail": NSNull(),
            ]
        }
        return [
            "surface": surface,
            "source": source,
            "surface_frame": inWindow(rig.view),
            "thread_frame": inWindow(host),
            "messages": messages,
            "avatars": [],
            "side_elements": [],
        ]
    }

    static func still(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func check(_ snapshot: URL) throws -> (Int32, String) {
        let script = repo.appendingPathComponent("tests/ui-structure/thread_structure.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", script.path, "check", snapshot.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
