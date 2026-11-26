import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the shipped Minimal sessions theme file (`Resources/theme-files/minimal-sessions.json`, Lawrence: "also
/// for customization make it possible to turn out sidebar into [a minimal session list]"), applied through the
/// app's own path (`MinimalSessionsPreset`: the file read by name, its overlay, `CmuxConfigSnapshot.parse`,
/// `SettingsApplier`, `applyListPreferences`), so the gallery shows what the file does, not hand-set fields.
/// A fixture with a row in every status (idle, working, busy, blocked on a permission, a question, done, error),
/// an unread row, a very long title, an emoji icon and a group, in each variant, dark and light. Written under
/// `minimal-sessions-gallery/` with `side-by-side.png` (stock left, the file right, dark on top, light below) and
/// `all.png`, bundled to `minimal-sessions-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMinimalSessionsGalleryTests {
    enum Variant: String, CaseIterable {
        /// Stock settings: no theme file.
        case `default`
        /// The shipped file as it is.
        case minimalSessions = "minimal-sessions"
        /// A copy of the file with the status back on the trailing column.
        case minimalSessionsTrailing = "minimal-sessions-trailing"
        /// A copy of the file with the workspace icon turned on: an idle row shows its icon in the status slot.
        case minimalSessionsIcons = "minimal-sessions-icons"

        /// The design the app holds with this variant chosen.
        func design() throws -> DesignSettings {
            guard self != .default else { return MinimalSessionsPreset.design(MinimalSessionsPreset.snapshot(nil)) }
            let shipped = try MinimalSessionsPreset.text()
            let (from, to): (String, String) = switch self {
            case .default, .minimalSessions: ("", "")
            case .minimalSessionsTrailing:
                (#""sidebar.workspaceRow.statusPlacement": "leading""#, #""sidebar.workspaceRow.statusPlacement": "trailing""#)
            case .minimalSessionsIcons: (#""sidebar.workspaceRow.icon": false"#, #""sidebar.workspaceRow.icon": true"#)
            }
            // A user's edited copy: the same file with one value changed.
            let text = from.isEmpty ? shipped : shipped.replacingOccurrences(of: from, with: to)
            if !from.isEmpty { try #require(text != shipped, "\(rawValue): the file no longer writes \(from)") }
            let overlay = MinimalSessionsPreset.overlay(text)
            #expect(overlay.diagnostics.isEmpty, "\(rawValue): \(overlay.diagnostics)")
            return MinimalSessionsPreset.design(MinimalSessionsPreset.snapshot(overlay))
        }
    }

    static func sections() -> [SidebarSection] {
        typealias Preset = MinimalSessionsPreset
        var group = CmuxNextSidebar.SidebarGroup(id: GroupID("g-design"), name: "Design review", color: .blue, workspaces: [
            Preset.workspace("w-tokens", "Color tokens", activity: .working(progress: nil)),
            Preset.workspace("w-icons", "Icon set pass"),
        ])
        group.icon = .emoji("🎨")
        return [SidebarSection(kind: .machine(Preset.machine), nodes: [
            .workspace(Preset.workspace("w-notes", "Notes")),
            .workspace(Preset.workspace("w-build", "Fix the build", activity: .working(progress: nil))),
            .workspace(Preset.workspace("w-tests", "npm test", activity: .busy(progress: nil))),
            .workspace(Preset.workspace("w-deploy", "Deploy staging", activity: .waiting(kind: .permission))),
            .workspace(Preset.workspace("w-db", "Pick a database", activity: .waiting(kind: .question))),
            .workspace(Preset.workspace("w-release", "Write release notes", activity: .success)),
            .workspace(Preset.workspace("w-migrate", "Migrate schema", activity: .error)),
            .workspace(Preset.workspace("w-review", "Review feedback", unread: .dot)),
            .workspace(Preset.workspace("w-long", "Refactor the sidebar renderer so that rows never shift when an agent "
                + "starts or stops, サイドバーの行が動かないように 🚀🧪 and keep going well past the edge")),
            .workspace(Preset.workspace("w-rocket", "Ship it", icon: .emoji("🚀"))),
            .workspace(Preset.workspace("w-rocket-busy", "Launch checklist", activity: .working(progress: nil), icon: .emoji("🛰️"))),
            .group(group),
        ])]
    }

    static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let design = try variant.design()
        return try MinimalSessionsPreset.with(design) {
            let width: CGFloat = 280, height: CGFloat = 460
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            root.wantsLayer = true
            root.appearance = window.appearance
            window.contentView = root
            let theme = dark ? "Soft Blue" : "Soft Blue Light"
            let input = try AANestedGroupsGalleryTests.input(theme)
            _ = ThemeScope.app.store.apply(input)
            let scope = ThemeScope(level: .room)
            scope.setOverride(ThemeSpec(theme), input: input, animated: false)
            scope.root(root)
            root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
            let model = SidebarModel(sections: sections())
            // As `SidebarView+Observation` hands the design's `sidebar.*` settings to the list.
            model.applyListPreferences(design.sidebarSections)
            let list = SidebarListView(model: model)
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
            root.addSubview(list)
            window.orderFrontRegardless()
            list.reload(animated: false)
            list.frame.origin.y = height - list.frame.height
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
            return try #require(rep.cgImage)
        }
    }

    /// `images` in a grid of `columns`, row by row from the top, on grey.
    static func grid(_ images: [CGImage], columns: Int) throws -> CGImage {
        let w = images[0].width, h = images[0].height, gap = 16
        let rows = (images.count + columns - 1) / columns
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: rows * h + (rows - 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (rows - 1 - row) * (h + gap), width: w, height: h))
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "minimal-sessions-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [String: CGImage] = [:]
        for dark in [true, false] {
            for variant in Variant.allCases {
                let image = try Self.render(variant, dark: dark)
                let name = "\(dark ? "dark" : "light")-\(variant.rawValue)"
                images[name] = image
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name).png"))
            }
        }
        let order = ["dark", "light"].flatMap { look in Variant.allCases.map { "\(look)-\($0.rawValue)" } }
        try AAGroupHeaderDensityGalleryTests.write(try Self.grid(order.compactMap { images[$0] }, columns: Variant.allCases.count),
                                                   to: out.appending(path: "all.png"))
        let pair = ["dark-default", "dark-minimal-sessions", "light-default", "light-minimal-sessions"]
        try AAGroupHeaderDensityGalleryTests.write(try Self.grid(pair.compactMap { images[$0] }, columns: 2),
                                                   to: out.appending(path: "side-by-side.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "minimal-sessions-gallery.tar", "minimal-sessions-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
