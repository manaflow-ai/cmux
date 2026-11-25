import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The working shelf (`sidebar.workingShelf`, off by default) drawn through the real sidebar: agent chats whose turn
/// ended and that wait on background work (`backgroundWaits > 0`) fold behind a "Working (N)" row and come back when
/// the wait ends or they need you. `off-dark` is the setting off (every row in place), `folded-*` has it on with the row
/// closed, `open-dark` with it open, `back-dark` after the job ended (waits 0, the chat in place). Set
/// CMUX_TEST_REQUIRE_GUI=1 to write PNGs under `studio-working-shelf-gallery/` with `all.png`, bundled to
/// `studio-working-shelf-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAStudioWorkingShelfGalleryTests {
    init() { Motion.reduceMotionOverride = true }

    struct Variant {
        let name: String
        let shelves: Bool
        let open: Bool
        let dark: Bool
        var jobEnded = false
    }

    static let variants = [
        Variant(name: "off-dark", shelves: false, open: false, dark: true),
        Variant(name: "folded-dark", shelves: true, open: false, dark: true),
        Variant(name: "folded-light", shelves: true, open: false, dark: false),
        Variant(name: "open-dark", shelves: true, open: true, dark: true),
        Variant(name: "back-dark", shelves: true, open: false, dark: true, jobEnded: true),
    ]

    static let selected = WorkspaceID("w-working")
    static let fold = SidebarDoneFoldID(section: .machine(.local), group: nil, kind: .working)

    /// A working chat (selected), one waiting on a job, one on a subagent and a watch, an unread chat with waits (stays),
    /// a terminal. `jobEnded` clears the first waiter's wait, as acpmux's summary does when the job finishes.
    static func rows(now: Date, jobEnded: Bool) -> [SidebarWorkspace] {
        func chat(_ id: String, _ title: String, minutesAgo: Double, working: Bool = false, waits: Int = 0,
                  unread: UnreadState = .none) -> SidebarWorkspace {
            var ws = SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: "~/Developer/todo-app",
                                      lastActivity: now.addingTimeInterval(-60 * minutesAgo), agentWorking: working, kind: .harness,
                                      unread: unread, activity: working ? .working(progress: nil) : .idle)
            ws.backgroundWaits = waits
            return ws
        }
        return [
            chat("working", "Add Due Dates to Todos", minutesAgo: 1, working: true),
            chat("job", "Run the Migration Dry Run", minutesAgo: 4, waits: jobEnded ? 0 : 1),
            chat("two", "Audit Retry Handlers", minutesAgo: 9, waits: 2),
            chat("unread", "Fix Invoice PDF Totals", minutesAgo: 14, waits: 1, unread: .dot),
            SidebarWorkspace(id: WorkspaceID("w-terminal"), title: "zsh", directory: "~/Developer/todo-app",
                             lastActivity: now.addingTimeInterval(-60 * 30)),
        ]
    }

    static func model(_ variant: Variant) -> SidebarModel {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let rows = rows(now: Date(), jobEnded: variant.jobEnded)
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))],
                                 activeWorkspaceID: selected)
        var preferences = SidebarSectionsPreferences.defaults
        preferences.showTimestamps = true
        model.applyListPreferences(preferences)
        model.shelvesWaiting = variant.shelves
        if variant.open { model.openDoneFolds = [fold] }
        return model
    }

    static func sidebar(_ variant: Variant, in root: NSView) -> SidebarView {
        let sidebar = SidebarView(model: model(variant), design: DesignSettings.shared)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        sidebar.renderNow()
        sidebar.updateBands()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.fitToClip()
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    static func keys(_ variant: Variant) -> [SidebarRowKey] {
        let model = model(variant)
        return SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions()).rows.map(\.key)
    }

    static func w(_ id: String) -> SidebarRowKey { .workspace(WorkspaceID("w-\(id)")) }

    // MARK: Checks

    @Test func offDrawsEveryRowInPlace() {
        let keys = Self.keys(Self.variants[0])
        #expect(!keys.contains(.doneFold(Self.fold)))
        #expect(["working", "job", "two", "unread", "terminal"].allSatisfy { keys.contains(Self.w($0)) })
    }

    @Test func waitingChatsFoldBehindTheWorkingRow() {
        let keys = Self.keys(Self.variants[1])
        #expect(keys.contains(.doneFold(Self.fold)))
        #expect(!keys.contains(Self.w("job")) && !keys.contains(Self.w("two")))
        #expect(["working", "unread", "terminal"].allSatisfy { keys.contains(Self.w($0)) }, "working, unread and terminal rows stay")
    }

    @Test func anOpenWorkingRowListsItsChatsUnderIt() throws {
        let keys = Self.keys(Self.variants[3])
        let fold = try #require(keys.firstIndex(of: .doneFold(Self.fold)))
        #expect(Array(keys[(fold + 1)...].prefix(2)) == [Self.w("job"), Self.w("two")])
    }

    @Test func aFinishedJobBringsTheChatBack() {
        let keys = Self.keys(Self.variants[4])
        #expect(keys.contains(Self.w("job")) && !keys.contains(Self.w("two")))
    }

    // MARK: Gallery

    static func render(_ variant: Variant) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 260, height: CGFloat = 360
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: variant.dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let (background, foreground, accent): (UInt32, UInt32, UInt32) = variant.dark ? (0x0B0B0B, 0xF5F5F5, 0x346BF1) : (0xFAFAFA, 0x18181B, 0x2563EB)
        var input = ThemeInput(background: ThemeRGB(hex: background), foreground: ThemeRGB(hex: foreground), palette: ThemeInput.ghosttyDefault.palette)
        input.accentColor = ThemeRGB(hex: accent)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Studio \(variant.dark ? "dark" : "light")"), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        window.orderFrontRegardless()
        let saved = DesignSettings.shared.sidebarSections.showTimestamps
        DesignSettings.shared.sidebarSections.showTimestamps = true
        defer { DesignSettings.shared.sidebarSections.showTimestamps = saved }
        _ = Self.sidebar(variant, in: root)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        defer { Motion.reduceMotionOverride = nil }
        let store = ThemeScope.app.store
        let original = store.input
        defer { _ = store.apply(original) }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "studio-working-shelf-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for variant in Self.variants {
            let image = try Self.render(variant)
            images.append(image)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.name).png"))
        }
        let w = images[0].width, h = images[0].height, gap = 16
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: images.count * w + (images.count - 1) * gap, height: h, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in images.enumerated() {
            ctx.draw(image, in: CGRect(x: index * (w + gap), y: 0, width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "studio-working-shelf-gallery.tar", "studio-working-shelf-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
