import AppKit
@testable import CmuxNextTasks
import Foundation
import Testing

/// Renders every prototype layout with the mock owner into PNGs for design
/// review. Runs only when TASKS_SNAPSHOT_DIR is set; the window is
/// borderless, off screen and never ordered front, so it takes no focus.
@MainActor
struct TasksSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TASKS_SNAPSHOT_DIR"] != nil))
    func renderPrototypeLayouts() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TASKS_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for layout in TasksLayout.allCases {
            let model = TasksModel(source: MockTasksSource())
            model.start()
            model.selection = "task_1"
            let host = TasksHostView(model: model, layout: layout)
            let size = NSSize(width: 1280, height: 760)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("tasks-\(layout.rawValue).png"))
            window.close()
        }
    }
}
