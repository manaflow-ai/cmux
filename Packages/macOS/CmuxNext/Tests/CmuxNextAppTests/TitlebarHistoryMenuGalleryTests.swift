import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHistory
import CmuxNextTestSupport
import Foundation
import Testing

/// The titlebar Back / Forward right-click list as it is today, then with Recently Closed in each
/// style (`history.menuStyle`), light and dark, each image labelled with its history rows, closed
/// rows and height against today's. Leo 2026-11-06: "don't increase any size ... after adding a
/// recently closed section, don't shrink it stupidly ... don't baloon it". An open NSMenu cannot be
/// drawn offscreen, so each row is laid out from the menu's own items (image, title, headers,
/// separators, a submenu's arrow) at the system menu's row height. Artifact
/// `titlebar-history-menu-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized, .closesItsWindows) struct TitlebarHistoryMenuGalleryTests {
    /// The menu's row height and separator height, as NSMenu draws them at the default font.
    static let rowHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 11

    static func place(_ tab: String, title: String, workspace: String, content: HistoryLocation.Content,
                      machine: String? = nil) -> HistoryLocation {
        HistoryLocation(key: .init(machine: machine ?? "local", tab: tab), window: "w1", workspace: workspace, pane: "p-\(tab)",
                        content: content, title: title, workspaceTitle: workspace, machineName: machine)
    }

    static let closed: [TitlebarHistoryClosedRow] = [
        .init(id: "daemon:1", kind: .browserTab, title: "Swift Testing docs", detail: "developer.apple.com"),
        .init(id: "daemon:2", kind: .terminalTab, title: "bun run dev", detail: "~/cmux/webviews"),
        .init(id: "daemon:3", kind: .screen, title: "Screen 2", detail: nil),
        .init(id: "daemon:4", kind: .workspace, title: "release-notes", detail: "build-server"),
        .init(id: "daemon:5", kind: .terminalTab, title: "htop", detail: "build-server"),
        .init(id: "daemon:6", kind: .browserTab, title: "GitHub — manaflow-ai/cmux", detail: "github.com"),
        .init(id: "daemon:7", kind: .terminalTab, title: "zsh", detail: "~"),
    ]

    /// A trail with a Back list of five places in two workspaces; `style` nil is today's menu (no Recently Closed).
    static func menu(_ style: TitlebarHistoryMenuStyle?) -> NSMenu {
        var trail = LocationTrail()
        let places = [
            place("t1", title: "cargo test -p cmux-tui", workspace: "cmux", content: .terminal),
            place("t2", title: "Fix the history menu titles", workspace: "cmux", content: .other),
            place("t3", title: "GitHub — manaflow-ai/cmux", workspace: "cmux", content: .browser),
            place("t4", title: "htop", workspace: "infra", content: .terminal, machine: "build-server"),
            place("t5", title: "Release notes", workspace: "docs", content: .other),
            place("t6", title: "zsh", workspace: "cmux", content: .terminal),
        ]
        for (step, location) in places.enumerated() {
            _ = trail.record(location, at: Date(timeIntervalSince1970: TimeInterval(step) * 60))
        }
        let sections = trail.menuSections(.back, scope: .workspace, layout: .scopeThenWindow)
        return TitlebarHistoryMenu.make(sections, closed: style.map { _ in .rows(closed) }, style: style ?? .inline, choose: { _ in },
                                        reopenRow: TitlebarHistoryMenuContentTests.reopenRow,
                                        showAll: NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    }

    struct Measure: Equatable {
        var historyRows: Int
        var closedRows: Int
        var height: CGFloat
        /// The widest title at the menu font, plus the image column NSMenu adds to every row when one has an image.
        var width: CGFloat
    }

    static func measure(_ menu: NSMenu) -> Measure {
        let history = menu.items.filter { $0.action == #selector(TitlebarHistoryMenuTarget.pick(_:)) }.count
        let closed = menu.items.filter { $0.identifier?.rawValue.hasPrefix("daemon:") == true }.count
        let height = menu.items.reduce(CGFloat(10)) { $0 + ($1.isSeparatorItem ? separatorHeight : rowHeight) }
        let items = menu.items + menu.items.flatMap { $0.submenu?.items ?? [] }
        let imageColumn: CGFloat = menu.items.contains { $0.image != nil } ? 22 : 0
        let width = (items.map { TitlebarHistoryMenu.titleWidth($0.title) }.max() ?? 0) + imageColumn
        return Measure(historyRows: history, closedRows: closed, height: height, width: width)
    }

    /// The menu's items as rows of a menu-like panel, `label` under it.
    static func panel(_ menu: NSMenu, label: String, appearance: NSAppearance) -> NSView {
        let width: CGFloat = 300
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        let hasIcons = menu.items.contains { $0.image != nil }
        for item in menu.items {
            if item.isSeparatorItem {
                let line = NSBox()
                line.boxType = .separator
                let wrap = NSStackView(views: [line])
                wrap.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
                wrap.heightAnchor.constraint(equalToConstant: separatorHeight).isActive = true
                wrap.widthAnchor.constraint(equalToConstant: width).isActive = true
                stack.addArrangedSubview(wrap)
                continue
            }
            let text = NSTextField(labelWithString: item.title)
            text.font = NSFont.menuFont(ofSize: 0)
            text.lineBreakMode = .byTruncatingTail
            if item.isSectionHeader {
                text.font = NSFont.systemFont(ofSize: TypeScale.caption, weight: .semibold)
                text.textColor = .secondaryLabelColor
            } else if !item.isEnabled {
                text.textColor = .tertiaryLabelColor
            }
            var views: [NSView] = []
            if let image = item.image {
                let icon = NSImageView(image: image)
                icon.contentTintColor = .labelColor
                icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
                views.append(icon)
            }
            views.append(text)
            if item.submenu != nil {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
                arrow.contentTintColor = .secondaryLabelColor
                views += [spacer, arrow]
            }
            let row = NSStackView(views: views)
            row.alignment = .centerY
            row.spacing = 6
            let indent: CGFloat = hasIcons && item.image == nil && !item.isSectionHeader ? 36 : 14
            row.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 14)
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(row)
        }
        let box = NSVisualEffectView()
        box.material = .menu
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        let caption = NSTextField(wrappingLabelWithString: label)
        caption.font = NSFont.systemFont(ofSize: TypeScale.caption)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = width
        caption.widthAnchor.constraint(equalToConstant: width).isActive = true
        let outer = NSStackView(views: [box, caption])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        outer.appearance = appearance
        box.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        outer.frame = NSRect(origin: .zero, size: outer.fittingSize)
        outer.layoutSubtreeIfNeeded()
        return outer
    }

    static func render(_ view: NSView) throws -> CGImage {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // ARC owns it; close() releasing it too crashed the run at the autorelease drain.
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
        window.appearance = view.appearance
        window.backgroundColor = view.appearance?.name == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// Leo's rule, measured on the gallery's own fixture: the history rows are today's, and Recently
    /// Closed adds a bounded block (at most `closedLimit` rows plus a header and a separator).
    @Test func everyVariantKeepsTodaysHistoryAndABoundedClosedBlock() {
        let today = Self.measure(Self.menu(nil))
        for style in TitlebarHistoryMenuStyle.allCases {
            let shown = Self.measure(Self.menu(style))
            #expect(shown.historyRows == today.historyRows)
            #expect(shown.closedRows <= TitlebarHistoryMenu.closedLimit)
            #expect(shown.height - today.height <= Self.separatorHeight + Self.rowHeight * CGFloat(1 + TitlebarHistoryMenu.closedLimit))
            // inlineIcons is one image column wider by design (its doc says so); the others keep today's width.
            #expect(shown.width <= max(today.width, TitlebarHistoryMenu.closedMinWidth) + (style == .inlineIcons ? 22 : 0))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderEveryStyle() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "titlebar-history-menu-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let today = Self.measure(Self.menu(nil))
        var lines: [String] = []
        let variants: [(String, TitlebarHistoryMenuStyle?)] = [("0-today", nil)] + TitlebarHistoryMenuStyle.allCases.enumerated().map {
            ("\($0.offset + 1)-\($0.element.rawValue)", $0.element)
        }
        for (name, style) in variants {
            let menu = Self.menu(style)
            let shown = Self.measure(menu)
            let label = style == nil
                ? "Today: \(today.historyRows) history rows, \(Int(today.height)) pt tall, widest row \(Int(today.width)) pt"
                : "\(style!.tunableTitle): \(shown.historyRows) history rows (today \(today.historyRows)), "
                    + "\(shown.closedRows) closed (max \(TitlebarHistoryMenu.closedLimit)), "
                    + "\(Int(shown.height)) pt (today \(Int(today.height)), +\(Int(shown.height - today.height))), "
                    + "widest row \(Int(shown.width)) pt (today \(Int(today.width)))"
            lines.append("\(name): \(label)")
            for (look, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let image = try Self.render(Self.panel(menu, label: label, appearance: try #require(NSAppearance(named: appearance))))
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(look).png"))
            }
        }
        print("titlebar-history-menu: " + lines.joined(separator: " | "))
        try lines.joined(separator: "\n").write(to: out.appending(path: "measurements.txt"), atomically: true, encoding: .utf8)
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "titlebar-history-menu-gallery.tar", "titlebar-history-menu-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}
