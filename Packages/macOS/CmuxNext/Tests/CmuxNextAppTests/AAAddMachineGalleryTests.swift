import AppKit
import CmuxNextDesign
@testable import CmuxNextServer
import CmuxNextTestSupport
import Foundation
import Testing

/// Stills of the Add Machine card. Leo, 2026-11-23: "stupid, stupid fucking call to have a symbol making space for
/// ABSOLUTLEY NOTHING and leaving so much bullshit blank space there ... get more creative with these lifeless-ass
/// fucking menus". Variants (``AddMachineCardSpec/Variant``), dark and light:
/// - `before`: the app icon's empty column, a printed subtitle, captioned fields;
/// - `lean` (shipped): no icon, the subtitle behind an info circle, captionless fields, the tailnet's machines to pick;
/// - `pickFirst`: the tailnet's machines first, the host to type under them, no Name;
/// - `minimal`: the host and the tailnet list.
/// Written under `add-machine-gallery/` with `all.png`, bundled to `add-machine-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAAddMachineGalleryTests {
    static let candidates = [
        HostCandidate(name: "studio", dnsName: "studio.tail1234.ts.net", ip: "100.64.0.2", os: "macOS", online: true, alreadyPeer: false, sshOK: true),
        HostCandidate(name: "build-box", dnsName: "build-box.tail1234.ts.net", ip: "100.64.0.3", os: "linux", online: true, alreadyPeer: true),
        HostCandidate(name: "old-laptop", dnsName: "old-laptop.tail1234.ts.net", ip: "100.64.0.4", os: "macOS", online: false, alreadyPeer: false),
    ]

    static func card(_ variant: AddMachineCardSpec.Variant) -> NSView {
        let spec = AddMachineCardSpec.pick(candidates: .loaded(candidates), values: [:], variant: variant)
        let view = CmuxDialogView(dialog: .standalone(spec) { _ in })
        view.frame.size = view.fittingSize
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "add-machine-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var columns: [[CGImage]] = []
        for dark in [true, false] {
            var images: [CGImage] = []
            for variant in AddMachineCardSpec.Variant.allCases {
                let image = try AAUpdateDownloadCardGalleryTests.render(Self.card(variant), dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.rawValue)-\(dark ? "dark" : "light").png"))
                images.append(image)
            }
            columns.append(images)
        }
        let gap = 16
        let cellW = columns.flatMap { $0 }.map(\.width).max() ?? 1
        let rows = AddMachineCardSpec.Variant.allCases.count
        let rowHeights = (0 ..< rows).map { row in columns.map { $0[row].height }.max() ?? 1 }
        let ctx = try #require(CGContext(data: nil, width: columns.count * cellW + (columns.count + 1) * gap,
                                         height: rowHeights.reduce(0, +) + (rows + 1) * gap,
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
        tar.arguments = ["cf", "add-machine-gallery.tar", "add-machine-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
