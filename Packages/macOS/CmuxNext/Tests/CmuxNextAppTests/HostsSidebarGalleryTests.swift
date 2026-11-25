import AppKit
@testable import CmuxNextAgentLanes
@testable import CmuxNextDesign
@testable import CmuxNextServer
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxNextWakeups
import CmuxTheme
import Foundation
import Testing

/// Native stills for the transient Hosts projection. The fixture is fed through the same
/// `SidebarModel.transientTopItems` path as the app bridge, so the captures cover the real
/// band placement and row renderer rather than a standalone row view. `CMUX_TEST_REQUIRE_GUI=1`
/// writes light/dark PNGs and `hosts-sidebar-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct HostsSidebarGalleryTests {
    struct Fixture: Sendable {
        let name: String
        let rows: [MachineSectionRow]
        let labsEnabled: Bool
    }

    static func machine(_ id: String, _ name: String, connected: Bool = true, connecting: Bool = false,
                        failed: Bool = false, failure: String? = nil, state: MachineServerState? = nil,
                        kind: MachineKind = .ssh) -> MachineSectionRow {
        MachineSectionRow(id: id, name: name, isConnected: connected, isLocal: false, kind: kind,
                          isConnecting: connecting, failed: failed, failure: failure, serverState: state)
    }

    /// The three state variants are deliberately distinct: ready, connecting and a terminal SSH failure.
    /// A local row keeps the projection anchored to the same mixed catalog the app supplies.
    static let fixtures: [Fixture] = [
        Fixture(name: "connected", rows: [
            machine("local", "This Mac", kind: .local),
            machine("build", "Build VM", kind: .cloud),
            machine("studio", "Studio SSH", kind: .ssh),
        ], labsEnabled: true),
        Fixture(name: "connecting", rows: [
            machine("local", "This Mac", kind: .local),
            machine("join", "Joining Host", connected: false, connecting: true),
            machine("build", "Build VM", kind: .cloud),
        ], labsEnabled: true),
        Fixture(name: "failed", rows: [
            machine("local", "This Mac", kind: .local),
            machine("broken", "Broken SSH", connected: false, failed: true, failure: "No route"),
            machine("paused", "Paused VM", connected: false, state: .paused, kind: .cloud),
        ], labsEnabled: true),
        Fixture(name: "labs-off", rows: [
            machine("local", "This Mac", kind: .local),
            machine("build", "Build VM", kind: .cloud),
        ], labsEnabled: false),
    ]

    static func sections() -> [SidebarSection] {
        let local = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspace = SidebarWorkspace(id: WorkspaceID("hosts-gallery-workspace"), title: "Local workspace",
                                         directory: "~/fun/cmux", branch: "hosts-gallery")
        return [SidebarSection(kind: .machine(local), nodes: [.workspace(workspace)])]
    }

    static func input(_ name: String) throws -> ThemeInput {
        try AANestedGroupsGalleryTests.input(name)
    }

    static func render(_ fixture: Fixture, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 300, height: CGFloat = 520
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let themeInput = try Self.input(theme)
        _ = ThemeScope.app.store.apply(themeInput)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: themeInput, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor

        let model = SidebarModel(sections: Self.sections())
        let hosts = HostsSidebar(host: .init(rows: { fixture.rows }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                                              enabled: { fixture.labsEnabled }))
        defer { hosts.stop() }
        model.transientTopItems = hosts.rows()
        let sidebar = SidebarView(model: model)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        root.layoutSubtreeIfNeeded()
        sidebar.renderNow()
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

    @Test func fixtureProjectionCoversOnAndOffStates() throws {
        let on = try #require(Self.fixtures.first(where: { $0.name == "connecting" }))
        let onRows = HostsSidebar.rows(machines: on.rows, expanded: true)
        #expect(onRows.contains { $0.info.title == "Hosts" })
        #expect(!onRows.contains { $0.info.caption == "Connecting…" })
        let off = try #require(Self.fixtures.first(where: { $0.name == "labs-off" }))
        let disabled = HostsSidebar(host: .init(rows: { off.rows }, add: {}, openConnected: { _ in }, openJoined: { _ in },
                                                 enabled: { off.labsEnabled }))
        defer { disabled.stop() }
        #expect(disabled.rows().isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "hosts-sidebar-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [[CGImage]] = []
        for (mode, theme, dark) in [("dark", "Soft Blue", true), ("light", "Soft Blue Light", false)] {
            var line: [CGImage] = []
            for fixture in Self.fixtures {
                let image = try Self.render(fixture, theme: theme, dark: dark)
                line.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(fixture.name)-\(mode).png"))
            }
            images.append(line)
        }
        let w = images[0][0].width, h = images[0][0].height, gap = 16
        let columns = Self.fixtures.count
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: 2 * h + gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (line, row) in images.enumerated() {
            for (column, image) in row.enumerated() {
                ctx.draw(image, in: CGRect(x: column * (w + gap), y: (1 - line) * (h + gap), width: w, height: h))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let request = ProcessRequest(URL(fileURLWithPath: "/usr/bin/tar"),
                                     ["cf", "hosts-sidebar-gallery.tar", "hosts-sidebar-gallery"],
                                     directory: root, timeout: .seconds(30))
        let result = try await AsyncProcess().run(request)
        #expect(result.succeeded)
    }
}
