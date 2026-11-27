import AppKit
import CmuxNextDesign
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the host's approval card, shown when another device asks to see or control this
/// Mac. Leo, 2026-11-16: "super ugly", and "i dont want to have to click share this mac allow every
/// single time when screen sharing". Variants on the cmux dialog card, each for a Full Control and a
/// View Only request, dark and light:
/// - `0-before`: the four answers (Allow Once, the two Always Allows, Deny) and "Asks for";
/// - `a-allow` (shipped): who asks and what it can do, what Allow keeps, then Allow (the hub's Always
///   at the scope asked for), Allow Only This Time and Not Now.
/// Written under `mac-screen-approval-gallery/` with `all.png`, bundled to
/// `mac-screen-approval-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAMacScreenApprovalGalleryTests {
    static let key = "3ef8f772cfdc66fe0cf4d64acf7b48a4" + String(repeating: "0", count: 32)

    static func request(_ scope: SessionScope) -> SessionRequest {
        SessionRequest(id: "gallery-\(scope)", viewerId: "v1", viewerName: "Desk Mac", viewerKeyFingerprint: key, scope: scope)
    }

    /// The card drawing `spec`, sized to fit.
    static func card(_ spec: CmuxDialogSpec) -> NSView {
        let view = CmuxDialogView(dialog: .standalone(spec) { _ in })
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The card as it shipped before: "Asks for", the fingerprint, then four answers.
    static func before(_ request: SessionRequest) -> NSView {
        let words = MacScreenApprovalWords(request)
        func button(_ choice: MacScreenApprovalChoice, _ role: CmuxDialogButton.Role) -> CmuxDialogButton {
            CmuxDialogButton(id: choice.rawValue, title: choice.title, role: role, personOnly: choice != .deny)
        }
        return card(CmuxDialogSpec(
            title: words.title,
            lines: ["Asks for \(request.scope == .full ? "Full Control" : "View Only")."],
            fields: [.code(label: "Device key fingerprint", text: MacScreenApprovalPrompt.fingerprintLines(key))],
            buttons: [button(.once, .default), button(.alwaysView, .normal), button(.alwaysFull, .normal), button(.deny, .cancel)],
            identifier: "macScreen.approval", layout: .stacked))
    }

    static let variants: [(String, (SessionRequest) -> NSView)] = [
        ("0-before", { before($0) }),
        ("a-allow", { card(MacScreenApprovalPrompt.spec($0, error: nil)) }),
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
