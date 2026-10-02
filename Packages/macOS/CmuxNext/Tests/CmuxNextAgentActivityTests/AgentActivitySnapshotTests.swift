import AppKit
@testable import CmuxNextAgentActivity
import Foundation
import Testing

/// Renders every prototype layout with the mock source into PNGs for design
/// review. Runs only when AGENT_ACTIVITY_SNAPSHOT_DIR is set; the window is
/// borderless, off screen and never ordered front, so it takes no focus.
@MainActor
struct AgentActivitySnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_ACTIVITY_SNAPSHOT_DIR"] != nil))
    func renderPrototypeLayouts() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["AGENT_ACTIVITY_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for layout in AgentActivityLayout.allCases {
                let model = AgentActivityModel(source: AgentActivityMockSource(now: Date()))
                model.start()
                model.select(session: "cua_n_01")
                model.step(-6)
                let host = AgentActivityHostView(model: model, layoutOverride: layout)
                let size = NSSize(width: 1280, height: 800)
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearanceName)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                // Let SwiftUI lay out and the async frame loads finish.
                for _ in 0..<40 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(25))
                }
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                let suffix = appearanceName == .aqua ? "light" : "dark"
                try png.write(to: directory.appendingPathComponent("agent-activity-\(layout.rawValue)-\(suffix).png"))
                window.close()
            }
        }
    }
}
