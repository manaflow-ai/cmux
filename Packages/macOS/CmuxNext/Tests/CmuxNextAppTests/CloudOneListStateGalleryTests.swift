import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing
import CmuxNextTestSupport

/// Before/after capture for Cloud machine state in the one-list sidebar. The existing machine
/// section stays unbound to RemoteMachinesSidebar; only each workspace's machine line gains the
/// live Paused, Connecting or Reconnecting state.
@MainActor @Suite(.closesItsWindows, .serialized)
struct CloudOneListStateGalleryTests {
    private static let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    static func sections(states: [SidebarMachine.Status]) -> [SidebarSection] {
        let cloudSections = states.enumerated().map { index, status in
            let machine = SidebarMachine(id: MachineID("cloud-\(index)"), name: "cloud-\(index + 1)", kind: .cloud, status: status)
            let workspace = SidebarWorkspace(id: WorkspaceID("cloud-workspace-\(index)"), machineID: machine.id,
                                             title: "Cloud workspace \(index + 1)")
            return SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])
        }
        let localWorkspace = SidebarWorkspace(id: WorkspaceID("local-workspace"), title: "Local workspace")
        return [SidebarSection(kind: .machine(local), nodes: [.workspace(localWorkspace)])] + cloudSections
    }

    static func render(states: [SidebarMachine.Status]) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 360, height: CGFloat = 260
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let input = try AANestedGroupsGalleryTests.input("Soft Blue")
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Soft Blue"), input: input, animated: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        scope.root(root)
        let model = SidebarModel(sections: sections(states: states))
        model.groupsByComputer = false
        let list = SidebarListView(model: model)
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    private static func archive(_ root: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.currentDirectoryURL = root
        process.arguments = ["cf", "cloud-one-list-state-gallery.tar", "cloud-one-list-state-gallery"]
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "tar exited \(status)"]) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderBeforeAfterGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "cloud-one-list-state-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let before = try Self.render(states: [.connected, .connected, .connected])
        let after = try Self.render(states: [.paused, .connecting, .reconnecting])
        try AAGroupHeaderDensityGalleryTests.write(before, to: out.appending(path: "before.png"))
        try AAGroupHeaderDensityGalleryTests.write(after, to: out.appending(path: "after.png"))
        let gap = 16
        let width = before.width + after.width + gap
        let height = max(before.height, after.height)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(before, in: CGRect(x: 0, y: 0, width: before.width, height: before.height))
        ctx.draw(after, in: CGRect(x: before.width + gap, y: 0, width: after.width, height: after.height))
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        try await Self.archive(root)
    }
}
