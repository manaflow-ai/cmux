import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the workspace hover card (Lawrence msg 19245, "alignment here looks bad ... not showing enough
/// details per each") over `WorkspaceHoverCardFixture`, the real card view on the real overlay glass, over a
/// busy terminal, dark and light. Written under `hover-card-variants/`, bundled to `hover-card-variants.tar`
/// for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkspaceHoverCardVariantsGalleryTests {
    static let canvas = NSSize(width: 360, height: 520)

    static func render(dark: Bool, make: () -> WorkspaceHoverCardView) throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: canvas), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = BusyBackdrop(frame: NSRect(origin: .zero, size: canvas))
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
        root.ink = scope.perform { Palette.textPrimary }
        let card = make()
        let host = HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() }
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        ])
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        card.applyColors()
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

    /// The shipped card as it is.
    static func current() -> WorkspaceHoverCardView {
        let card = WorkspaceHoverCardView()
        card.configure(WorkspaceHoverCardFixture.content, now: WorkspaceHoverCardFixture.now)
        card.tabList.configure(title: WorkspaceHoverCardFixture.title, tabs: WorkspaceHoverCardFixture.tabs)
        return card
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "hover-card-variants")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [true, false] {
            let image = try Self.render(dark: dark, make: Self.current)
            try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "current-\(dark ? "dark" : "light").png"))
        }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "hover-card-variants.tar", "hover-card-variants"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

/// A terminal's worth of text behind the card: what a hover card covers while the person works.
private final class BusyBackdrop: NSView {
    var ink: NSColor = .labelColor
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let lines = [
            "$ swift test --filter WorkspaceTabHoverCardTests", "Building for debugging...",
            "[312/1290] Compiling CmuxNextSidebar WorkspaceHoverCard.swift", "warning: var 'x' was never mutated",
            "Test Suite 'WorkspaceTabHoverCardTests' started", "✔ Test clickingAnInactiveWorkspaceTab passed (0.21s)",
            "✔ Test cardStartsWithTabsAndCollapsedDetails passed", "git log --oneline -5", "d4773687fb62 cmux NEXT: name Cmd-N chat",
            "0ffea12ac93f fix(sidebar): stable drop overlay", "~/fun/cmux on feat-cmux-next [!?] via 🦀 1.88",
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ink.withAlphaComponent(0.85),
        ]
        var y: CGFloat = 4
        var index = 0
        while y < bounds.height {
            (lines[index % lines.count] as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
            y += 15
            index += 1
        }
    }
}
