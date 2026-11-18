import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// Three sidebar widths, in light/dark and flat/grouped layouts. These are the mounted list rows,
/// including long machine/project names, local Share, Mac/Cloud View, offline Mac, and Linux SSH.
/// `renderStates` adds the screen control's states (rest, hover, selected, This Mac sharing) for each glyph variant
/// (Leo 2026-11-16, on the share arrow drawn on every row: "Holy moly is THIS the icon for screen sharing???").
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarScreenActionsGalleryTests {
    enum State: String, CaseIterable { case rest, hover, selected, sharing }

    /// The glyph variants compared: the share arrow it replaced, then three screens. `display` (the pack's
    /// `remote.display`) is the one landed.
    static let variants: [(name: String, symbol: String?)] = [
        ("before-share-arrow", "square.and.arrow.up"), ("display", nil),
        ("person-on-screen", "rectangle.inset.filled.and.person.filled"), ("screen-mirroring", "rectangle.on.rectangle"),
    ]

    static func render(width: CGFloat, grouped: Bool, theme: String, dark: Bool,
                       state: State? = nil, symbol: String? = nil, before: Bool = false) throws -> CGImage {
        _ = NSApplication.shared
        let height: CGFloat = 640
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        var sections = SidebarScreenActionTests.examples
        if state == .sharing { sections[0] = SidebarScreenActionTests.sharedLocal() }
        let model = SidebarModel(sections: sections)
        model.groupsByComputer = grouped
        let list = SidebarListView(model: model)
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        root.layoutSubtreeIfNeeded()
        // One hovered Mac beside resting Cloud/offline rows captures the primary action and
        // the existing secondary controls together, at each width and appearance.
        let hovered = grouped ? list.rowViews[.section(.machine(MachineID("mac")))] : list.rowViews[.workspace(WorkspaceID("ws-mac"))]
        switch state {
        case nil, .hover?: hovered?.isHovered = true
        case .selected?: list.rowViews[.workspace(WorkspaceID("ws-cloud"))]?.isSelected = true
        case .sharing?:
            let local = list.rowViews[.workspace(WorkspaceID("ws-local"))] as? WorkspaceRowView
            local?.isSelected = true
            local?.isOnScreen = true
        case .rest?: break
        }
        for row in list.rowViews.values { row.needsLayout = true }
        root.layoutSubtreeIfNeeded()
        if let symbol {
            for view in AANestedGroupsGalleryTests.all(root) {
                guard let button = view as? SidebarIconButton, button.accessibilityIdentifier().hasSuffix(".screen")
                    || button.accessibilityIdentifier() == "cmux.sidebar.list.shareScreen" else { continue }
                button.setSymbol(symbol)
                // The before picture: the share arrow drawn on every row at rest, as Leo saw it.
                if before { button.isHidden = false; button.alphaValue = 1 }
            }
        }
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderStates() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-screen-actions-gallery/states")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for variant in Self.variants {
            for state in State.allCases {
                for grouped in [false, true] {
                    for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                        let image = try Self.render(width: 300, grouped: grouped, theme: theme, dark: dark, state: state,
                                                    symbol: variant.symbol, before: variant.name == "before-share-arrow")
                        let name = "\(variant.name)-\(state.rawValue)-\(grouped ? "grouped" : "flat")-\(mode).png"
                        let dest = try #require(CGImageDestinationCreateWithURL(out.appending(path: name) as CFURL, "public.png" as CFString, 1, nil))
                        CGImageDestinationAddImage(dest, image, nil)
                        #expect(CGImageDestinationFinalize(dest))
                    }
                }
            }
        }
        // One file for `cmux-ci run --artifact`, as the nested-groups gallery bundles its stills.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = AANestedGroupsGalleryTests.packageRoot
        tar.arguments = ["cf", "sidebar-screen-actions-gallery.tar", "sidebar-screen-actions-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-screen-actions-gallery")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for width: CGFloat in [240, 300, 360] {
            for grouped in [false, true] {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(width: width, grouped: grouped, theme: theme, dark: dark)
                    let name = "\(Int(width))-\(grouped ? "grouped" : "flat")-\(mode).png"
                    let dest = try #require(CGImageDestinationCreateWithURL(out.appending(path: name) as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                }
            }
        }
    }
}
