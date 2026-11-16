import AppKit
import CmuxNextDesign
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the host's approval panel, shown when another device asks to see or control this
/// Mac. Leo, 2026-11-16: "super ugly", and "i dont want to have to click share this mac allow every
/// single time when screen sharing". Variants, each for a Full Control and a View Only request,
/// dark and light:
/// - `0-before`: as it shipped (four answers in a grid, the key fingerprint always shown);
/// - `a-allow` (shipped): one primary Allow, which the hub remembers for that Mac, a quiet Not Now,
///   and Details, which opens below the buttons (`a-allow-details`) with the key and Allow Only This Time;
/// - `b-remember`: Allow and Not Now with a "Don't ask again" switch above them;
/// - `c-row`: a compact banner, the words on the left and Allow over Not Now on the right.
/// Written under `mac-screen-approval-gallery/` with `all.png`, bundled to
/// `mac-screen-approval-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMacScreenApprovalGalleryTests {
    static let width = MacScreenApprovalView.width
    static let key = "3ef8f772cfdc66fe0cf4d64acf7b48a4" + String(repeating: "0", count: 32)

    static func request(_ scope: SessionScope) -> SessionRequest {
        SessionRequest(id: "gallery-\(scope)", viewerId: "v1", viewerName: "Desk Mac", viewerKeyFingerprint: key, scope: scope)
    }

    /// A themed panel surface holding `content`, sized to it at the panel's width.
    final class Panel: MacScreenThemedView {
        let stack = MacScreenStack.make(.vertical, spacing: 12, alignment: .leading,
                                        insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        init(width: CGFloat, _ rows: [NSView]) {
            super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            let background = MacScreenFill(\.popup, shape: .rounded(Metrics.panelCornerRadius), bordered: true)
            background.frame = bounds
            background.autoresizingMask = [.width, .height]
            addSubview(background)
            background.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.topAnchor.constraint(equalTo: background.topAnchor),
                stack.widthAnchor.constraint(equalToConstant: width),
            ])
            for row in rows { MacScreenStack.addFullWidth(row, to: stack) }
            frame.size = NSSize(width: width, height: ceil(stack.fittingSize.height))
            paint(self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }
    }

    static func header(_ request: SessionRequest, width: CGFloat) -> NSView {
        let words = MacScreenApprovalWords(request)
        let text = MacScreenStack.make(.vertical, spacing: 3, alignment: .leading, [
            MacScreenText(words.title, font: MacScreenType.emphasized, wraps: true, width: width),
            MacScreenText(words.body, font: MacScreenType.body, ink: \.secondary, wraps: true, width: width),
        ])
        for view in text.arrangedSubviews { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return MacScreenStack.make(.horizontal, spacing: 12, alignment: .top,
                                   [MacScreenGlyph(words.symbol, font: MacScreenType.glyph, ink: \.accent, width: 28), text])
    }

    /// The panel as it shipped before: title, "Asks for", the fingerprint, then four answers.
    static func before(_ request: SessionRequest) -> NSView {
        let words = MacScreenApprovalWords(request)
        let title = MacScreenStack.make(.horizontal, spacing: 10, alignment: .centerY, [
            MacScreenGlyph(words.symbol, font: MacScreenType.glyph, ink: \.accent),
            MacScreenText(words.title, font: MacScreenType.emphasized, wraps: true, width: 300),
        ])
        let row = MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
            MacScreenButton("Deny", role: .destructive) {}, MacScreenSpacer(min: 8), MacScreenButton("Allow Once", role: .primary) {},
        ])
        return Panel(width: 380, [
            title,
            MacScreenText("Asks for \(request.scope == .full ? "Full Control" : "View Only").", font: MacScreenType.body, ink: \.secondary),
            MacScreenStack.make(.vertical, spacing: 2, alignment: .leading, [
                MacScreenText("Device key fingerprint", font: MacScreenType.caption, ink: \.secondary),
                MacScreenText(words.key ?? "", font: MacScreenType.code),
            ]),
            row,
            MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
                MacScreenButton("Always Allow View Only", compact: true) {}, MacScreenButton("Always Allow Full Control", compact: true) {},
            ]),
        ])
    }

    /// The shipped view, Details closed or open.
    static func shipped(_ request: SessionRequest, details: Bool) -> MacScreenApprovalView {
        let prompt = MacScreenApprovalPrompt()
        prompt.present = { _ in }
        prompt.update([request])
        let view = MacScreenApprovalView(prompt: prompt)
        if details { view.toggleDetails() }
        view.frame.size = view.fittingSize
        return view
    }

    static func remember(_ request: SessionRequest) -> NSView {
        let toggle = MacScreenSwitch(id: "gallery.remember", label: "Don't ask again")
        toggle.isOn = true
        let check = MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
            toggle, MacScreenText("Don’t ask again for \(request.viewerName)", font: MacScreenType.body, ink: \.secondary),
        ])
        let buttons = MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [
            MacScreenButton("Details", role: .quiet, compact: true) {}, MacScreenSpacer(min: 8),
            MacScreenButton("Not Now") {}, MacScreenButton("Allow", role: .primary) {},
        ])
        return Panel(width: width, [header(request, width: MacScreenApprovalView.textWidth), check, buttons])
    }

    static func row(_ request: SessionRequest) -> NSView {
        let textWidth: CGFloat = 230
        let words = MacScreenStack.make(.vertical, spacing: 6, alignment: .leading, [
            header(request, width: textWidth - 40), MacScreenButton("Details", role: .quiet, compact: true) {},
        ])
        let allow = MacScreenButton("Allow", role: .primary) {}
        let notNow = MacScreenButton("Not Now") {}
        let answers = MacScreenStack.make(.vertical, spacing: 6, alignment: .trailing, [allow, notNow])
        notNow.widthAnchor.constraint(equalTo: allow.widthAnchor).isActive = true
        return Panel(width: 380, [MacScreenStack.make(.horizontal, spacing: 12, alignment: .top, [words, MacScreenSpacer(min: 0), answers])])
    }

    static let variants: [(String, (SessionRequest) -> NSView)] = [
        ("0-before", { before($0) }),
        ("a-allow", { shipped($0, details: false) }),
        ("a-allow-details", { shipped($0, details: true) }),
        ("b-remember", { remember($0) }),
        ("c-row", { row($0) }),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "mac-screen-approval-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Columns: dark full, dark view, light full, light view; one row per variant.
        var columns: [[CGImage]] = []
        for dark in [true, false] {
            for scope in [SessionScope.full, .view] {
                var images: [CGImage] = []
                for (name, make) in Self.variants {
                    let image = try AAUpdateDownloadCardGalleryTests.render(make(Self.request(scope)), dark: dark)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(name)-\(scope)-\(dark ? "dark" : "light").png"))
                    images.append(image)
                }
                columns.append(images)
            }
        }
        let gap = 16
        let cellW = columns.flatMap { $0 }.map(\.width).max() ?? 1
        let rowHeights = (0 ..< Self.variants.count).map { row in columns.map { $0[row].height }.max() ?? 1 }
        let ctx = try #require(CGContext(data: nil, width: columns.count * cellW + (columns.count + 1) * gap,
                                         height: rowHeights.reduce(0, +) + (rowHeights.count + 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (column, images) in columns.enumerated() {
            var top = ctx.height - gap
            for (row, image) in images.enumerated() {
                ctx.draw(image, in: CGRect(x: gap + column * (cellW + gap), y: top - image.height, width: image.width, height: image.height))
                top -= rowHeights[row] + gap
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "mac-screen-approval-gallery.tar", "mac-screen-approval-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
