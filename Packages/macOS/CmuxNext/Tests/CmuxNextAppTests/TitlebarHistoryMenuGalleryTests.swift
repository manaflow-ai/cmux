import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextHistory
import Foundation
import Testing

/// The titlebar Back / Forward right-click list in each row style (`history.menuStyle`), light
/// and dark, with Recently Closed and Show Full History (Leo's ask relayed 2026-11-06: "roomy,
/// readable"). An open NSMenu cannot be drawn offscreen, so each row is laid out from the menu's
/// own items (image, attributed title, headers, separators) at the system menu's metrics.
/// Artifact `titlebar-history-menu-gallery.tar` (`CMUX_TEST_REQUIRE_GUI=1`).
@MainActor @Suite(.serialized) struct TitlebarHistoryMenuGalleryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func place(_ tab: String, title: String, workspace: String, content: HistoryLocation.Content,
                      machine: String? = nil) -> HistoryLocation {
        HistoryLocation(key: .init(machine: machine ?? "local", tab: tab), window: "w1", workspace: workspace, pane: "p-\(tab)",
                        content: content, title: title, workspaceTitle: workspace, machineName: machine)
    }

    /// A trail with a Back list of three places, a fixture closed history of four items.
    static func menu(_ style: TitlebarHistoryMenuStyle) -> NSMenu {
        var trail = LocationTrail()
        let places = [
            place("t1", title: "cargo test -p cmux-tui", workspace: "cmux", content: .terminal),
            place("t2", title: "Fix the history menu titles", workspace: "cmux", content: .other),
            place("t3", title: "GitHub — manaflow-ai/cmux", workspace: "cmux", content: .browser),
            place("t4", title: "htop", workspace: "cmux", content: .terminal, machine: "gcp-lane-2"),
            place("t5", title: "zsh", workspace: "cmux", content: .terminal),
        ]
        for (step, location) in places.enumerated() {
            _ = trail.record(location, at: now.addingTimeInterval(TimeInterval(step - places.count) * 420))
        }
        let sections = trail.menuSections(.back, scope: .window, layout: .scopeThenWindow)
        let closed: [TitlebarHistoryClosedRow] = [
            .init(id: "daemon:1", kind: .browserTab, title: "Swift Testing docs", detail: "developer.apple.com", time: now.addingTimeInterval(-90)),
            .init(id: "daemon:2", kind: .terminalTab, title: "bun run dev", detail: "~/cmux/webviews", time: now.addingTimeInterval(-1_500)),
            .init(id: "daemon:3", kind: .screen, title: "Screen 2", detail: nil, time: now.addingTimeInterval(-7_200)),
            .init(id: "daemon:4", kind: .workspace, title: "release-notes", detail: "gcp-lane-2", time: now.addingTimeInterval(-90_000)),
        ]
        return TitlebarHistoryMenu.make(sections, closed: .rows(closed), style: style, now: now, choose: { _ in },
                                        showAll: NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    }

    /// The menu's items as rows of a menu-like panel.
    static func panel(_ menu: NSMenu, appearance: NSAppearance) -> NSView {
        let width = max(menu.minimumWidth, 260)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
        for item in menu.items {
            if item.isSeparatorItem {
                let line = NSBox()
                line.boxType = .separator
                line.widthAnchor.constraint(equalToConstant: width - 20).isActive = true
                let wrap = NSStackView(views: [line])
                wrap.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
                stack.addArrangedSubview(wrap)
                continue
            }
            let text = NSTextField(labelWithString: item.title)
            if let attributed = item.attributedTitle { text.attributedStringValue = attributed }
            text.font = text.font ?? NSFont.menuFont(ofSize: TypeScale.body)
            if item.isSectionHeader {
                text.font = NSFont.menuFont(ofSize: TypeScale.caption).withWeight(.semibold)
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
            let row = NSStackView(views: views)
            row.alignment = .centerY
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 3, left: item.image == nil && !item.isSectionHeader && menu.minimumWidth > 0 ? 36 : 14,
                                          bottom: 3, right: 14)
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(row)
        }
        let box = NSVisualEffectView()
        box.material = .menu
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.appearance = appearance
        box.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.frame = NSRect(origin: .zero, size: stack.fittingSize)
        box.layoutSubtreeIfNeeded()
        return box
    }

    static func render(_ view: NSView) throws -> CGImage {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -40_000, y: -40_000))
        window.appearance = view.appearance
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test func everyStyleListsTheSameRows() {
        let counts = TitlebarHistoryMenuStyle.allCases.map { Self.menu($0).items.count }
        #expect(Set(counts).count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderEveryStyle() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "titlebar-history-menu-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for style in TitlebarHistoryMenuStyle.allCases {
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let look = try #require(NSAppearance(named: appearance))
                let image = try Self.render(Self.panel(Self.menu(style), appearance: look))
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(style.rawValue)-\(name).png"))
            }
        }
        let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.currentDirectoryURL = root
        tar.arguments = ["cf", "titlebar-history-menu-gallery.tar", "titlebar-history-menu-gallery"]
        try tar.run(); tar.waitUntilExit(); #expect(tar.terminationStatus == 0)
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
