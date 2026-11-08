import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Film strips for Leo 2026-11-08 ("when workspaces get renamed (esp by agents) it should have that same fade in
/// animation that the tool call situation has"): the middle of five workspace rows is renamed by a row patch, and
/// each strip shows it at 0, 30, 60, 90, 120 and 180 ms, left to right, dark and light:
/// - `swap-*`: the shared text swap (`MotionGate.swapText`, the agent chat's `useTextSwap`), the one that ships;
/// - `fade-*`: the same timings with no rise (opacity only);
/// - `crossfade-*`: the old `sidebar.workspaceTitleMotion` crossfade (a CATransition fade over `crossfade`).
/// Each frame poses the old words' snapshot and the new words from the same `TextSwapMotion` the app animates (a
/// layer capture shows the model, not an animation in flight). The rows above and below stand still in every frame.
/// Written under `title-text-swap-gallery/` and bundled to `title-text-swap-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATitleTextSwapGalleryTests {
    static let times: [TimeInterval] = [0, 0.03, 0.06, 0.09, 0.12, 0.18]
    static let names = ["Release notes", "Docs", "New chat", "Review the PR", "Terminal"]
    static let renamed = "Fix the flaky login test"

    enum Variant: String, CaseIterable {
        case swap, fade, crossfade

        /// The old words' and the new words' poses `time` seconds in.
        func poses(at time: TimeInterval) -> (old: TextSwapMotion.Pose, new: TextSwapMotion.Pose) {
            let swap = TextSwapMotion(style: .rise, outDuration: MotionScale.micro, inDuration: MotionScale.standard)
            switch self {
            case .swap:
                return (swap.outgoing(at: time), swap.incoming(at: time))
            case .fade:
                var (old, new) = (swap.outgoing(at: time), swap.incoming(at: time))
                (old.y, new.y) = (0, 0)
                return (old, new)
            case .crossfade:
                // The CATransition fade the old variant added: both texts over `crossfade` on the ease-out curve.
                let progress = TextSwapMotion.ease(time / MotionScale.quick)
                return (.init(opacity: 1 - progress, y: 0), .init(opacity: progress, y: 0))
            }
        }
    }

    static func snapshot(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// `frames` side by side, a gap apart.
    static func strip(_ frames: [CGImage]) throws -> CGImage {
        let gap = 12
        let width = frames.reduce(0) { $0 + $1.width } + gap * (frames.count - 1)
        let height = frames.map(\.height).max() ?? 0
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for frame in frames {
            context.draw(frame, in: CGRect(x: x, y: height - frame.height, width: frame.width, height: frame.height))
            x += frame.width + gap
        }
        return try #require(context.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let previous = Motion.reduceMotionOverride
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = previous }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "title-text-swap-gallery")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.removeItem(at: root.appending(path: "title-text-swap-gallery.tar"))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = Self.names.indices.map { WorkspaceID("swap-\($0)") }
        for dark in [true, false] {
            let theme = dark ? "dark" : "light"
            let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: zip(ids, Self.names).map {
                .workspace(SidebarWorkspace(id: $0, title: $1))
            })], activeWorkspaceID: ids[0])
            let sidebar = SidebarView(model: model, design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 190)
            let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.closeAfterTest() }
            window.contentView = sidebar
            try AADragStartGalleryTests.theme(window, dark: dark)
            window.orderFrontRegardless()
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            let row = try #require(sidebar.list.rowViews[.workspace(ids[2])] as? WorkspaceRowView)
            let rowLayer = try #require(row.layer)
            let titleLayer = try #require(row.title.layer)
            try AAGroupHeaderDensityGalleryTests.write(AADragStartGalleryTests.shot(window), to: out.appending(path: "before-\(theme).png"))
            let old = try Self.snapshot(row.title)

            // The rename as it reaches the row: the row patch path; the gallery poses the swap itself.
            var ws = try #require(sidebar.list.workspaces[ids[2]])
            ws.title = Self.renamed
            #expect(model.patchWorkspaces([ws]))
            #expect(!MotionGate.textSwapGhosts(of: titleLayer).isEmpty, "the patch swapped the title")
            Motion.sidebar.cancelTextSwap(in: row.title)
            let new = try Self.snapshot(row.title)
            let content = try #require(window.contentView)
            let rest = AANestedGroupsGalleryTests.all(content).map(\.frame)
            try AAGroupHeaderDensityGalleryTests.write(AADragStartGalleryTests.shot(window), to: out.appending(path: "after-\(theme).png"))

            row.title.alphaValue = 0
            let down = MotionGate.textSwapDown(in: row.title)
            let layers = [old, new].map { image in
                let layer = CALayer()
                layer.frame = titleLayer.frame
                layer.contents = image
                layer.contentsGravity = .resize
                layer.contentsScale = window.backingScaleFactor
                rowLayer.insertSublayer(layer, above: titleLayer)
                return layer
            }
            for variant in Variant.allCases {
                var frames: [CGImage] = []
                for time in Self.times {
                    let (oldPose, newPose) = variant.poses(at: time)
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for (layer, pose) in zip(layers, [oldPose, newPose]) {
                        layer.opacity = Float(pose.opacity)
                        layer.transform = CATransform3DMakeTranslation(0, CGFloat(pose.y) * down, 0)
                    }
                    CATransaction.commit()
                    frames.append(try AADragStartGalleryTests.shot(window))
                    #expect(AANestedGroupsGalleryTests.all(content).map(\.frame) == rest,
                            "\(variant) at \(Int(time * 1000)) ms: no view moved")
                }
                try AAGroupHeaderDensityGalleryTests.write(Self.strip(frames), to: out.appending(path: "\(variant.rawValue)-\(theme).png"))
            }
            layers.forEach { $0.removeFromSuperlayer() }
            row.title.alphaValue = 1
        }
        try """
        Workspace title rename film strips (Leo 2026-11-08). Each strip: 0, 30, 60, 90, 120, 180 ms, left to right.
        swap-*: the shared text swap (ships). fade-*: same timings, no rise. crossfade-*: the old CATransition crossfade.
        before-* and after-*: the sidebar at rest before and after the rename.

        """.write(to: out.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "title-text-swap-gallery.tar", "title-text-swap-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
