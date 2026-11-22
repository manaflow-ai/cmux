import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// How a sidebar row shows its agent chat's task list (`SidebarTaskProgressLook`), redone after Leo 2026-11-22: "the
/// fact they fucking render in the motherfucking sidebar workspaces is a huge fucking trip. like, offensively fucking
/// useless right now. if we ever EVER FUCKING WANT SOME BULLSHIT LIKE THIS, WE FUCKING DO IT PROPERLY. SO GO DO IT
/// PROPERLY." He saw "limit 0/1 •": the title cut to one word by a "0/1" count.
///
/// One still per look and layout, dark and light: `before` (the Nov 20 count on the name's line, drawn the way it
/// drew: a dim one-line status), then every `SidebarTaskProgressLook`. Layouts: a narrow and a wide sidebar of
/// one-line rows, a wide one of two-line rows (the Directory element on) and the expanded density. Rows: a 1-step list,
/// a 5-step and a 120-step one working (the last with a long step title), a 5-step one waiting on the person, and a
/// chat with no list. Plus the working chat's hover card, which every look keeps. Written under
/// `sidebar-task-plan-gallery/` with `all-dark.png` and `all-light.png` (a look per row of the sheet, a layout per
/// column), bundled to `sidebar-task-plan-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AASidebarTaskPlanGalleryTests {
    /// The stills' looks: the shipped one before this change, then each look there is.
    enum Look: Hashable {
        case before
        case look(SidebarTaskProgressLook)

        static var all: [Look] { [.before] + SidebarTaskProgressLook.allCases.map(Look.look) }
        var name: String {
            switch self {
            case .before: "before"
            case let .look(look): look.rawValue + (look == .shipped ? "-picked" : "")
            }
        }
    }

    enum Layout: String, CaseIterable {
        case narrow = "narrow-one-line", wide = "wide-one-line", twoLine = "wide-two-line", expanded = "wide-expanded"
        var width: CGFloat { self == .narrow ? 220 : 320 }
    }

    static func sections(before: Bool) -> [SidebarSection] {
        func chat(_ id: String, _ title: String, folder: String, message: String, tasks: SidebarTaskProgress?,
                  activity: StatusIndicatorState = .working(progress: nil), unread: UnreadState = .none) -> SidebarWorkspace {
            let working = if case .working = activity { true } else { false }
            var ws = SidebarWorkspace(id: WorkspaceID("p-\(id)"), title: title, directory: folder, agentWorking: working,
                                      kind: .harness, unread: unread, activity: activity, agentBrand: "claude")
            ws.lastMessage = message
            if before {
                // The Nov 20 look: the count as the row's dim one-line status (`trailingStatus`).
                ws.status = tasks.map { "\($0.done)/\($0.total)" }
            } else {
                ws.taskProgress = tasks
            }
            return ws
        }
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(chat("limit", "limit the retry queue to fifty", folder: "~/code/cmux", message: "Capped it at 50",
                            tasks: SidebarTaskProgress(done: 0, total: 1, current: "Cap the retry queue at 50"))),
            .workspace(chat("passkey", "Fix the passkey sign-in", folder: "~/code/web", message: "The prompt test is red",
                            tasks: SidebarTaskProgress(done: 1, total: 5, current: "Write the red test for the passkey prompt",
                                                       next: "Fix the WebAuthn bridge"))),
            .workspace(chat("billing", "Migrate the billing tables", folder: "~/code/platform", message: "Batch 37 of 120 done",
                            tasks: SidebarTaskProgress(done: 37, total: 120,
                                                       current: "Backfill invoice_line_items for every Stripe customer created before the 2024 schema change",
                                                       next: "Backfill batch 39"))),
            .workspace(chat("cloud", "Ship the Cloud billing page", folder: "~/code/web", message: "Which plan names?",
                            tasks: SidebarTaskProgress(done: 3, total: 5, current: "Wire the plan picker", next: "Stripe webhook"),
                            activity: .waiting, unread: .dot)),
            .workspace(chat("notes", "Release notes", folder: "~/code/cmux", message: "Drafted", tasks: nil, activity: .idle)),
        ])]
    }

    static func render(_ look: Look, _ layout: Layout, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let density: SidebarDensity = layout == .expanded ? .expanded : layout == .twoLine ? .comfortable : .compact
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        let width = layout.width, height: CGFloat = 250
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        let model = SidebarModel(sections: sections(before: look == .before))
        model.expanded = layout == .expanded
        var shown = WorkspaceRowElements.standard.shown
        if layout == .twoLine { shown.insert(.directory) }
        if look == .before { shown.insert(.agentStatus) }
        model.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: shown))
        if case let .look(value) = look { model.taskProgressLook = value } else { model.taskProgressLook = .hidden }
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
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    static func hoverCard(dark: Bool) throws -> CGImage {
        let ws = try #require(sections(before: false).first?.nodes.compactMap { node -> SidebarWorkspace? in
            if case let .workspace(ws) = node, ws.id.rawValue == "p-passkey" { return ws } else { return nil }
        }.first)
        return try AAWorkspaceHoverCardVariantsGalleryTests.render(dark: dark) {
            let card = WorkspaceHoverCardView(style: .standard)
            card.configure(WorkspaceHoverCardContent.make(ws, machine: nil, now: Date()), now: Date())
            return card
        }
    }

    /// A contact sheet: one row per look (its name on the left), one column per layout.
    static func sheet(_ images: [[CGImage]], names: [String], dark: Bool) throws -> CGImage {
        let gap = 16, label = 170
        let widths = images[0].map(\.width), h = images.map { $0.map(\.height).max() ?? 0 }.max() ?? 0
        let width = label + widths.reduce(0, +) + gap * widths.count, height = images.count * (h + gap) + gap
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: dark ? 0.3 : 0.75, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (row, line) in images.enumerated() {
            let y = height - (row + 1) * (h + gap)
            var x = label
            (names[row] as NSString).draw(at: NSPoint(x: 12, y: y + h - 40), withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: dark ? NSColor.white : NSColor.black,
            ])
            for image in line {
                ctx.draw(image, in: CGRect(x: x, y: y + h - image.height, width: image.width, height: image.height))
                x += image.width + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(ctx.makeImage())
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "sidebar-task-plan-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            var sheet: [[CGImage]] = []
            for look in Look.all {
                var line: [CGImage] = []
                for layout in Layout.allCases {
                    let image = try Self.render(look, layout, dark: dark)
                    line.append(image)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(mode)-\(look.name)-\(layout.rawValue).png"))
                }
                sheet.append(line)
            }
            try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(sheet, names: Look.all.map(\.name), dark: dark),
                                                       to: out.appending(path: "all-\(mode).png"))
            try AAGroupHeaderDensityGalleryTests.write(try Self.hoverCard(dark: dark), to: out.appending(path: "\(mode)-hover-card.png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "sidebar-task-plan-gallery.tar", "sidebar-task-plan-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
