import AppKit
@testable import CmuxNextAppHealth
import CmuxNextControl
@testable import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Before and after stills of app health's "needs a repair" alert (David Beyer, 2026-11-20: it did not say which
/// chat): the footer line over the card, dark and light. Before: the parts have no place, as the app shipped
/// ("Agent chat needs a repair", Done and Repair now). After: the chat's title in the line and the title, its
/// workspace under it, and Show chat. Written under `app-health-card-gallery/` as `before-dark.png`,
/// `after-dark.png`, `before-light.png`, `after-light.png` and `all.png`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAAppHealthCardGalleryTests {
    static let failed: JSONValue = [
        "id": "page:7", "kind": "page", "label": "Agent chat", "state": "failed", "sinceMs": 0,
        "detail": "Not answering for 2 min. Tried 3 repairs without luck; it tries again by itself within 10 min, or click to try now; your draft is kept.",
        "action": "restartRenderer", "attempt": 3, "maxAttempts": 3, "nextAtMs": .null, "canRepair": true,
    ]
    static let snapshot: JSONValue = ["worst": "failed", "parts": [failed], "receipts": [], "pending": [], "pendingMore": 0]

    static let after = AppHealthPlaces { id in
        id == "page:7" ? AppHealthPlace(chat: "Fix the login bug", workspace: "cmux-next", reveal: {}) : nil
    }

    /// The footer line over the card, as the person sees them in turn.
    static func still(_ places: AppHealthPlaces, dark: Bool) throws -> CGImage {
        let line = AppHealthIndicatorView()
        line.show(places.headline(AppHealth.headline(of: snapshot)))
        let size = line.fittingSize
        line.frame = NSRect(x: 0, y: 0, width: min(size.width, AAAppHealthIndicatorGalleryTests.width), height: max(size.height, 18))
        let card = AAMacScreenApprovalGalleryTests.card(AppHealthCard.spec(snapshot, places: places))
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: max(line.frame.width, card.frame.width), height: line.frame.height + 16 + card.frame.height))
        card.frame.origin = .zero
        line.frame.origin = NSPoint(x: 0, y: card.frame.height + 16)
        stack.addSubview(card)
        stack.addSubview(line)
        return try AAUpdateDownloadCardGalleryTests.render(stack, dark: dark)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "app-health-card-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var cells: [CGImage] = []
        for dark in [true, false] {
            for (name, places) in [("before", AppHealthPlaces.none), ("after", Self.after)] {
                let image = try Self.still(places, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
                cells.append(image)
            }
        }
        // all.png: before | after, dark row over light row.
        let gap = 16
        let cellW = cells.map(\.width).max() ?? 1, cellH = cells.map(\.height).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: 2 * cellW + 3 * gap, height: 2 * cellH + 3 * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (index, image) in cells.enumerated() {
            let column = index % 2, row = index / 2
            let top = ctx.height - gap - row * (cellH + gap)
            ctx.draw(image, in: CGRect(x: gap + column * (cellW + gap), y: top - image.height, width: image.width, height: image.height))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
    }
}
