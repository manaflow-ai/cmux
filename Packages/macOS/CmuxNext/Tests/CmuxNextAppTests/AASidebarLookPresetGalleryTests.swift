import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Sidebar looks (`sidebar.look`: cmux, claude, codex, studio) drawn through the real list, and the
/// no-shift detector. Leo 2026-11-18: "make sure stuff is faithful + doesn't shift".
///
/// The detector reads every row's frame in the list:
/// - a row changing state (working, waiting, error, done, unread, idle again) moves no row;
/// - a hot reload of the same look moves no row;
/// - switching looks keeps every workspace row's height and the list's width (the shared grid), and
///   switching back puts every row back where it was.
/// Each look is resolved the way the app resolves it: `SidebarLookPreset.filling` over the file,
/// then the sidebar settings parse, then the model's list preferences.
///
/// Set CMUX_TEST_REQUIRE_GUI=1 to write `sidebar-look-presets-gallery/` (dark above, light below,
/// one column per look, `all.png`), bundled to `sidebar-look-presets-gallery.tar`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarLookPresetGalleryTests {
    static let looks = SidebarLookPreset.values
    static let folder = AANestedGroupsGalleryTests.repoRoot.appending(path: "Resources/sidebar-looks", directoryHint: .isDirectory)
    static let changing = WorkspaceID("w-cache")
    static let width: CGFloat = 280, height: CGFloat = 420

    static func workspace(_ id: String, _ title: String, _ folder: String, minutesAgo: Double,
                          activity: StatusIndicatorState = .idle, unread: UnreadState = .none) -> SidebarWorkspace {
        var ws = SidebarWorkspace(id: WorkspaceID("w-\(id)"), title: title, directory: folder, branch: "main",
                                  rowKind: .agent, kind: .terminal, activity: activity)
        ws.lastActivity = Date().addingTimeInterval(-minutesAgo * 60)
        ws.unread = unread
        return ws
    }

    /// Two projects' chats, as a person with a few agents running has them.
    static func rows(changing state: StatusIndicatorState = .idle, unread: UnreadState = .none) -> [SidebarWorkspace] {
        [
            workspace("sidebar", "Sidebar look presets", "~/cmux", minutesAgo: 0, activity: .working(progress: nil)),
            workspace("cache", "Cache the projection request", "~/cmux", minutesAgo: 5, activity: state, unread: unread),
            workspace("review", "Review the row layout editor", "~/cmux", minutesAgo: 42),
            workspace("deploy", "Deploy the docs site", "~/site", minutesAgo: 90, activity: .waiting(kind: nil)),
            workspace("copy", "Plain copy for the pricing page", "~/site", minutesAgo: 60 * 26),
            workspace("flaky", "Flaky upload test", "~/site", minutesAgo: 60 * 50, activity: .error),
        ]
    }

    static func sections(_ rows: [SidebarWorkspace]) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })]
    }

    /// Look `look`'s sidebar preferences, resolved as the settings load resolves them.
    static func preferences(_ look: String, over file: JSONValue = .object([:])) -> SidebarSectionsPreferences {
        let root = file.setting(.string(look), at: SidebarLookPreset.configPath)
        var diagnostics: [SettingsDiagnostic] = []
        let prefs = SidebarSectionsSetting.parse(SidebarLookPreset.filling(root, folder: folder), diagnostics: &diagnostics)
        #expect(diagnostics.isEmpty, "\(look): \(diagnostics)")
        return prefs
    }

    @MainActor final class Harness {
        let window: NSWindow
        let root: NSView
        let model: SidebarModel
        let list: SidebarListView

        init(look: String, dark: Bool = true, width: CGFloat = AASidebarLookPresetGalleryTests.width) throws {
            _ = NSApplication.shared
            let height = AASidebarLookPresetGalleryTests.height
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
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
            let start = AASidebarLookPresetGalleryTests.sections(AASidebarLookPresetGalleryTests.rows())
            model = SidebarModel(sections: start, activeWorkspaceID: WorkspaceID("w-review"))
            list = SidebarListView(model: model)
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
            root.addSubview(list)
            window.orderFrontRegardless()
            apply(look: look)
        }

        func apply(look: String) {
            model.applyListPreferences(AASidebarLookPresetGalleryTests.preferences(look))
            settle()
        }

        func patch(_ rows: [SidebarWorkspace]) {
            _ = model.patchWorkspaces(rows)
            settle()
        }

        func settle() {
            list.reload(animated: false)
            root.layoutSubtreeIfNeeded()
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layoutSubtreeIfNeeded()
                view.layer?.removeAllAnimations()
            }
        }

        /// Every drawn row's frame, by row.
        var frames: [SidebarRowKey: CGRect] { list.rowViews.mapValues(\.frame) }

        /// The heights of the workspace rows.
        var workspaceHeights: Set<CGFloat> {
            Set(list.rowViews.compactMap { key, view in
                if case .workspace = key { view.frame.height } else { nil }
            })
        }

        func image() throws -> CGImage {
            for view in AANestedGroupsGalleryTests.all(root) {
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return try #require(rep.cgImage)
        }

        func close() { window.close() }
    }

    static func describe(_ a: [SidebarRowKey: CGRect], _ b: [SidebarRowKey: CGRect]) -> String {
        let keys = Set(a.keys).union(b.keys)
        return keys.filter { a[$0] != b[$0] }.map { "\($0): \(a[$0].map { "\($0)" } ?? "none") -> \(b[$0].map { "\($0)" } ?? "none")" }
            .sorted().joined(separator: "; ")
    }

    @Test func everyShippedLookFillsOnlyPublicSettingsAndTheDefaultFillsNothing() {
        let empty: JSONValue = .object([:])
        #expect(SidebarLookPreset.filling(empty.setting(.string("cmux"), at: SidebarLookPreset.configPath), folder: Self.folder)
            == empty.setting(.string("cmux"), at: SidebarLookPreset.configPath))
        for look in Self.looks where look != SidebarLookPreset.fallback {
            let values = SidebarLookPreset.entries(of: look, folder: Self.folder)
            #expect(!values.isEmpty, "\(look) has a file")
            for entry in values { #expect(SettingsSchema.descriptor(for: entry.path) != nil, "\(look): \(entry.path)") }
        }
        // A person's own value wins over the look's.
        let mine = empty.setting(.string("folder"), at: ["sidebar", "groupBy"]).setting(.string("claude"), at: SidebarLookPreset.configPath)
        #expect(SidebarLookPreset.filling(mine, folder: Self.folder).value(at: ["sidebar", "groupBy"])?.stringValue == "folder")
    }

    /// The detector, part one: within each look, a row changing state or a reload moves no row.
    @Test(arguments: SidebarLookPreset.values)
    func aRowChangingStateOrAReloadMovesNoRow(_ look: String) throws {
        let harness = try Harness(look: look)
        defer { harness.close() }
        let rest = harness.frames
        #expect(!rest.isEmpty)
        let states: [(StatusIndicatorState, UnreadState)] = [
            (.working(progress: nil), .none), (.busy(progress: 0.4), .none), (.waiting(kind: nil), .none),
            (.error, .none), (.success, .dot), (.success, .count(3)), (.idle, .none),
        ]
        for (state, unread) in states {
            harness.patch(Self.rows(changing: state, unread: unread))
            let now = harness.frames
            #expect(now == rest, "\(look), \(state) \(unread): \(Self.describe(rest, now))")
        }
        harness.apply(look: look)
        #expect(harness.frames == rest, "\(look), reload: \(Self.describe(rest, harness.frames))")
    }

    /// The detector, part two: switching looks keeps the grid (row height, list width) and switching
    /// back puts every row back.
    @Test func switchingLooksKeepsTheGridAndSwitchingBackMovesNothing() throws {
        let harness = try Harness(look: SidebarLookPreset.fallback)
        defer { harness.close() }
        let width = harness.list.frame.width
        var heights: [String: Set<CGFloat>] = [:]
        var frames: [String: [SidebarRowKey: CGRect]] = [:]
        for look in Self.looks {
            harness.apply(look: look)
            heights[look] = harness.workspaceHeights
            frames[look] = harness.frames
            #expect(harness.list.frame.width == width, "\(look) keeps the list's width")
            #expect(harness.workspaceHeights.count == 1, "\(look): one row height, \(harness.workspaceHeights)")
        }
        #expect(Set(heights.values).count == 1, "every look keeps the row height: \(heights)")
        for from in Self.looks {
            for to in Self.looks where to != from {
                harness.apply(look: from)
                harness.apply(look: to)
                harness.apply(look: from)
                #expect(harness.frames == frames[from], "\(from) -> \(to) -> \(from): \(Self.describe(frames[from] ?? [:], harness.frames))")
            }
        }
    }

    /// Each look's reference sidebar width (measured from the reference captures; the look itself never sets
    /// width), so a still sits beside its reference at the same size.
    static let referenceWidths: [String: CGFloat] = ["cmux": 280, "claude": 288, "codex": 300, "studio": 256]

    /// What the faithfulness score compares against the reference: the list's width, every workspace
    /// row's height and pitch, the header heights, and the title and detail type.
    static func metrics(_ harness: Harness) -> [String: Any] {
        func weight(_ font: NSFont) -> Double {
            let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
        }
        var rows: [CGRect] = [], headers: [CGFloat] = []
        for (key, view) in harness.list.rowViews {
            switch key {
            case .workspace: rows.append(view.frame)
            case .group, .folder, .listHeader, .section: headers.append(view.frame.height)
            default: break
            }
        }
        let ys = rows.map(\.minY).sorted()
        let pitches = zip(ys, ys.dropFirst()).map { $1 - $0 }
        return [
            "width": harness.list.frame.width,
            "rowHeights": Array(Set(rows.map(\.height))).sorted(),
            "rowPitchMin": pitches.min() ?? 0,
            "headerHeights": Array(Set(headers)).sorted(),
            "titleSize": SidebarStyle.titleFont.pointSize, "titleWeight": weight(SidebarStyle.titleFont),
            "detailSize": SidebarStyle.subtitleFont.pointSize,
            "headerSize": SidebarStyle.headerFont.pointSize, "headerWeight": weight(SidebarStyle.headerFont),
        ]
    }

    /// Stills at each look's reference width (dark, as every reference is), their metrics, and a switch's
    /// before, after and back stills (the frames check is `switchingLooksKeepsTheGridAndSwitchingBackMovesNothing`;
    /// a spinner's phase makes pixels differ, so the stills are for review).
    func renderFaithfulness(into out: URL) throws {
        var all: [String: Any] = [:]
        for look in Self.looks {
            let harness = try Harness(look: look, dark: true, width: Self.referenceWidths[look] ?? Self.width)
            try AAGroupHeaderDensityGalleryTests.write(try harness.image(), to: out.appending(path: "reference-width-\(look).png"))
            all[look] = Self.metrics(harness)
            harness.close()
        }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appending(path: "metrics.json"))
        for look in Self.looks where look != SidebarLookPreset.fallback {
            let harness = try Harness(look: SidebarLookPreset.fallback)
            defer { harness.close() }
            let before = try harness.image()
            harness.apply(look: look)
            let after = try harness.image()
            harness.apply(look: SidebarLookPreset.fallback)
            let back = try harness.image()
            for (name, image) in [("before", before), ("after", after), ("back", back)] {
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "switch-\(look)-\(name).png"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-look-presets-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for look in Self.looks {
                let harness = try Harness(look: look, dark: dark)
                let image = try harness.image()
                harness.close()
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(look).png"))
            }
        }
        let columns = Self.looks.count
        let w = images[0].width, h = images[0].height, gap = 16
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: 2 * h + gap, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        try renderFaithfulness(into: out)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-look-presets-gallery.tar", "sidebar-look-presets-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
