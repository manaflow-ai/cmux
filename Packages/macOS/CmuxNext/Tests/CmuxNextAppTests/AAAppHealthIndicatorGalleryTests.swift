import AppKit
@testable import CmuxNextAppHealth
import CmuxNextControl
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of app health's sidebar entry (design/app-health.md; #39247): the footer line in its three
/// treatments (`a-line`, shipped; `b-chip`; `c-dot`) in each state (healthy shows nothing, a restore that
/// is slow, a part not responding, a queued action alone), and the "Restoring sessions…" card with its
/// Details, dark and light. The popover's own states are the web gallery's (`ui.app-health`). Written
/// under `app-health-indicator-gallery/` with `all.png`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAAppHealthIndicatorGalleryTests {
    static let width = SidebarBottomCardSlot.cardWidth(in: 220)

    static func headline(_ parts: [JSONValue], pending: [JSONValue] = []) -> AppHealth.Headline? {
        AppHealth.headline(of: ["worst": "healthy", "parts": .array(parts), "receipts": [], "pending": .array(pending), "pendingMore": 0])
    }

    static func part(_ label: String, _ state: String) -> JSONValue {
        ["id": .string(label), "kind": "sessionDaemon", "label": .string(label), "state": .string(state), "detail": "", "canRepair": false, "sinceMs": 0]
    }

    static let states: [(String, AppHealth.Headline?)] = [
        ("1-healthy", headline([])),
        ("2-restoring-slow", headline([part("Session service", "slow")])),
        ("3-not-responding", headline([part("Agent chat", "stuck")])),
        ("4-queued-close", headline([], pending: [["id": "close", "label": "close Background task", "sinceMs": 0]])),
    ]

    /// A footer line in `style` showing `headline`; a healthy one draws as an empty line of the same height.
    static func line(_ headline: AppHealth.Headline?, style: AppHealthIndicatorView.Style, dark: Bool) throws -> CGImage {
        let view = AppHealthIndicatorView()
        view.style = style
        view.show(headline)
        view.isHidden = false
        let size = view.fittingSize
        view.frame = NSRect(x: 0, y: 0, width: min(max(size.width, 24), width), height: max(size.height, 18))
        return try AAUpdateDownloadCardGalleryTests.render(view, dark: dark)
    }

    @Test func eachStateSaysWhatTheWebIndicatorSays() {
        let view = AppHealthIndicatorView()
        view.show(Self.states[0].1)
        #expect(view.isHidden, "healthy shows nothing")
        view.show(Self.states[2].1)
        #expect(!view.isHidden && view.text == "Agent chat: Not responding" && view.tone == .danger)
        view.show(Self.states[1].1)
        #expect(view.text == "Session service: Slow" && view.tone == .attention)
        view.show(Self.states[3].1)
        #expect(view.text == "Reconnecting; will close Background task when back" && view.tone == .muted)
        var pressed = false
        view.onPress = { pressed = true }
        #expect(view.accessibilityPerformPress() && pressed)
    }

    /// Codex's review of #39247 at 39099ce: the line sits after the avatar, at a nonzero origin in the
    /// footer, and a click there must reach it (AppKit hit-tests in the superview's coordinates).
    @Test func aClickOnTheLineAfterTheAvatarReachesIt() {
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 30))
        let view = AppHealthIndicatorView()
        footer.addSubview(view)
        view.show(Self.states[2].1)
        view.frame = NSRect(x: 40, y: 6, width: 150, height: 18)
        view.layoutSubtreeIfNeeded()
        #expect(footer.hitTest(NSPoint(x: 60, y: 15)) === view, "a click on the label")
        #expect(footer.hitTest(NSPoint(x: 42, y: 15)) === view, "a click on the dot")
        #expect(footer.hitTest(NSPoint(x: 20, y: 15)) !== view, "a click on the avatar's place")
        view.show(Self.states[0].1)
        #expect(footer.hitTest(NSPoint(x: 60, y: 15)) !== view, "a hidden line takes no click")
    }

    @Test func theRestoringCardsDetailsIsOptIn() {
        #expect(SidebarNoticeCard.restoring("Restoring sessions… 4m 12s").actions.isEmpty)
        let card = SidebarNoticeCard.restoring("Restoring sessions… 4m 12s", withDetails: true)
        #expect(card.actions.map(\.id) == [SidebarNoticeCard.detailsAction] && card.actions.allSatisfy { !$0.prominent })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "app-health-indicator-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let restoring = SidebarNoticeCard.restoring("Restoring sessions… 4m 12s", withDetails: true)
        var columns: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for (index, style) in AppHealthIndicatorView.Style.allCases.enumerated() {
                for (state, headline) in Self.states {
                    let image = try Self.line(headline, style: style, dark: dark)
                    let name = "\(["a-line", "b-chip", "c-dot"][index])-\(state)-\(dark ? "dark" : "light").png"
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: name))
                    images.append(image)
                }
            }
            let card = try AASidebarNoticeCardGalleryTests.notice(restoring, width: Self.width, placement: .above, dark: dark)
            try AAGroupHeaderDensityGalleryTests.write(card, to: out.appending(path: "restoring-details-\(dark ? "dark" : "light").png"))
            images.append(card)
            columns.append(images)
        }
        let gap = 16
        let cellW = columns.flatMap { $0 }.map(\.width).max() ?? 1
        let heights = columns[0].map(\.height)
        let ctx = try #require(CGContext(data: nil, width: 2 * cellW + 3 * gap, height: heights.reduce(0, +) + (heights.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (column, images) in columns.enumerated() {
            var top = ctx.height - gap
            for image in images {
                top -= image.height
                ctx.draw(image, in: CGRect(x: gap + column * (cellW + gap), y: top, width: image.width, height: image.height))
                top -= gap
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
    }
}
