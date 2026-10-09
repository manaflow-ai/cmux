import AppKit
import Foundation
import ImageIO
import Metal
import QuartzCore
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextDesign
@testable import CmuxNextSidebar

/// The status icon candidate sets side by side (cx-kxa2, Lawrence
/// 2026-10-08: "make sure i can try a bunch of different icons so we can
/// search for the best one together"): rows = sets, columns = states, at
/// 10, 12, 16 and 32 pt, in Ghostty's default dark theme and GitHub Light
/// Default, plus real sidebar rows per set. Frames come from `CARenderer`
/// (the Core Animation compositor), so animations, replicators and masks
/// render as on screen. Writes one self-contained HTML file,
/// `<package>/.build/status-icons/contact-sheet.html` (and
/// `$NX_ARTIFACTS/status-icons-contact-sheet.html`). Renderer helpers follow
/// StatusStatesSheetTests (feat-cmux-next-status-icons).
@MainActor @Suite(.serialized) struct StatusIconSetSheetTests {
    struct Look {
        let name: String
        let tokens: ThemeTokens
        let input: ThemeInput
    }

    static let dark = ThemeInput.ghosttyDefault
    static let light = ThemeInput(
        background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328),
        palette: [
            0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
            0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
        ].map { ThemeRGB(hex: $0) })
    static let looks = [
        Look(name: "Dark (Ghostty default)", tokens: ThemeTokens.derive(from: dark), input: dark),
        Look(name: "Light (GitHub Light Default)", tokens: ThemeTokens.derive(from: light), input: light),
    ]

    static let states: [(String, StatusIndicatorState)] = [
        ("working", .working), ("blocked: permission", .waiting(kind: .permission)), ("blocked: question", .waiting(kind: .question)),
        ("blocked: auth", .waiting(kind: .auth)), ("blocked", .waiting), ("done", .success), ("error", .error), ("idle", .idle),
        ("working 40%", .working(progress: 0.4)),
    ]

    static let slots: [CGFloat] = [10, 12, 16, 32]
    static let fps = 15.0
    static let seconds = 2.4

    static func colors(_ tokens: ThemeTokens) -> StatusIndicatorLayer.Colors {
        StatusIndicatorLayer.Colors(
            loading: tokens.textSecondary.nsColor.cgColor, attention: tokens.attention.nsColor.cgColor,
            danger: tokens.danger.nsColor.cgColor, success: tokens.success.nsColor.cgColor,
            accent: tokens.textPrimary.nsColor.cgColor)
    }

    static func text(_ string: String, _ color: CGColor, size: CGFloat, frame: CGRect) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        layer.font = NSFont.systemFont(ofSize: size, weight: .medium)
        layer.fontSize = size
        layer.foregroundColor = color
        layer.contentsScale = 2
        layer.frame = frame
        layer.isWrapped = false
        layer.truncationMode = .end
        return layer
    }

    /// One table: rows = sets, columns = states, one slot size.
    static func matrix(_ look: Look, slot: CGFloat) -> CALayer {
        let colWidth = max(92, slot + 40)
        let rowHeight = max(28, slot + 16)
        let labelWidth: CGFloat = 150
        let width = labelWidth + CGFloat(states.count) * colWidth + 12
        let height = 26 + CGFloat(StatusIconSet.allCases.count) * rowHeight + 8
        let root = CALayer()
        root.isGeometryFlipped = true
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.backgroundColor = look.tokens.surfaceBackground.withAlpha(1).nsColor.cgColor
        let label = look.tokens.textSecondary.nsColor.cgColor
        for (c, state) in states.enumerated() {
            root.addSublayer(text(state.0, label, size: 10, frame: CGRect(x: labelWidth + CGFloat(c) * colWidth, y: 6, width: colWidth - 4, height: 16)))
        }
        for (r, set) in StatusIconSet.allCases.enumerated() {
            let y = 26 + CGFloat(r) * rowHeight
            root.addSublayer(text(set.tunableTitle, label, size: 11, frame: CGRect(x: 8, y: y + (rowHeight - 14) / 2, width: labelWidth - 8, height: 16)))
            let config = StatusIndicatorConfig(iconSet: set)
            for (c, state) in states.enumerated() {
                let indicator = StatusIndicatorLayer()
                root.addSublayer(indicator.layer)
                indicator.contentsScale = 2
                indicator.hostIsFlipped = true
                indicator.colors = colors(look.tokens)
                indicator.frame = CGRect(x: labelWidth + CGFloat(c) * colWidth + 6, y: y + (rowHeight - slot) / 2, width: slot, height: slot)
                indicator.apply(.make(state.1, style: .arc, animates: true, set: set), config: config)
                keep.append(indicator)
            }
        }
        return root
    }

    /// Real sidebar rows in `look`'s theme, drawn with the shared config's set.
    static func sidebar(_ look: Look) -> NSView {
        func ws(_ n: Int, _ title: String, _ status: String?, _ activity: StatusIndicatorState, unread: UnreadState = .none) -> SidebarWorkspace {
            SidebarWorkspace(id: WorkspaceID("icons-\(n)"), title: title, directory: "~/fun/cmux", status: status,
                             icon: nil, unread: unread, activity: activity)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let sections = [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(ws(1, "agent working", "Claude: working", .working)),
            .workspace(ws(2, "needs permission", "Codex: run rm -rf build?", .waiting(kind: .permission), unread: .dot)),
            .workspace(ws(3, "asks a question", "Which branch?", .waiting(kind: .question))),
            .workspace(ws(4, "needs sign-in", "gh auth login", .waiting(kind: .auth))),
            .workspace(ws(5, "done, unseen", "zig build done in 2m 14s", .success)),
            .workspace(ws(6, "error", "Migration failed (exit 1)", .error, unread: .count(1))),
        ])]
        let model = SidebarModel(sections: sections, activeWorkspaceID: WorkspaceID("icons-0"))
        let scope = ThemeScope(level: .room)
        scope.setOverride(nil, input: look.input, animated: false)
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 250)
        sidebar.wantsLayer = true
        sidebar.appearance = scope.appearance
        scope.root(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.setWindowVisible(true)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.displayIfNeeded()
        scopes.append(scope)
        return sidebar
    }

    static var keep: [StatusIndicatorLayer] = []
    static var scopes: [ThemeScope] = []

    /// Renders `layer` with the Core Animation compositor at `count` times,
    /// `1 / fps` apart, starting now.
    static func frames(of layer: CALayer, count: Int) throws -> [CGImage] {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw SheetError.noMetal }
        let scale: CGFloat = 2
        let width = Int(layer.bounds.width * scale), height = Int(layer.bounds.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SheetError.noMetal }
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue: queue,
        ])
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        host.isGeometryFlipped = true
        let holder = CALayer()
        holder.frame = host.bounds
        holder.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        host.addSublayer(holder)
        layer.removeFromSuperlayer()
        layer.frame.origin = .zero
        holder.addSublayer(layer)
        renderer.layer = host
        renderer.bounds = host.bounds
        let start = CACurrentMediaTime()
        var images: [CGImage] = []
        for index in 0..<count {
            renderer.beginFrame(atTime: start + Double(index) / fps, timeStamp: nil)
            renderer.addUpdate(renderer.bounds)
            renderer.render()
            renderer.endFrame()
            guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { throw SheetError.noMetal }
            blit.synchronize(resource: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                      decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SheetError.noImage }
            images.append(image)
        }
        layer.removeFromSuperlayer()
        return images
    }

    enum SheetError: Error { case noMetal, noImage }

    static func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    static func gif(_ images: [CGImage]) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, images.count, nil) else { return Data() }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func img(_ data: Data, _ mime: String, width: Int) -> String {
        "<img style=\"width:\(width)px\" src=\"data:\(mime);base64,\(data.base64EncodedString())\">"
    }

    @Test func writesTheContactSheet() throws {
        Motion.reduceMotionOverride = false
        let previous = StatusIndicatorAppearance.shared.config
        defer {
            Motion.reduceMotionOverride = nil
            StatusIndicatorAppearance.shared.apply(previous)
            Self.keep.removeAll()
            Self.scopes.removeAll()
        }
        let count = Int(Self.seconds * Self.fps)
        var body = ""
        var anyMotion = false
        for look in Self.looks {
            body += "<h2>\(look.name)</h2>"
            for slot in Self.slots {
                let layer = Self.matrix(look, slot: slot)
                let width = Int(layer.bounds.width)
                let images = try Self.frames(of: layer, count: count)
                anyMotion = anyMotion || Self.png(images[0]) != Self.png(images[count / 3])
                body += "<h3>\(Int(slot)) pt slot</h3><div class=\"pair\"><figure>\(Self.img(Self.gif(images), "image/gif", width: width))<figcaption>animated (\(count) frames, \(Int(Self.fps)) fps)</figcaption></figure>"
                body += "<figure>\(Self.img(Self.png(images[0]), "image/png", width: width))<figcaption>first frame (the still look under Reduce Motion)</figcaption></figure></div>"
            }
            body += "<h3>Sidebar rows (real SidebarView), one per set</h3><div class=\"pair\">"
            for set in StatusIconSet.allCases {
                var config = previous
                config.iconSet = set
                StatusIndicatorAppearance.shared.apply(config)
                let sidebar = Self.sidebar(look)
                guard let layer = sidebar.layer else { continue }
                let images = try Self.frames(of: layer, count: count)
                body += "<figure>\(Self.img(Self.gif(images), "image/gif", width: 240))<figcaption>\(set.tunableTitle) (<code>\(set.rawValue)</code>)</figcaption></figure>"
            }
            body += "</div>"
        }
        var legend = ""
        for set in StatusIconSet.allCases {
            legend += "<tr><td><code>\(set.rawValue)</code></td><td>\(set.tunableTitle)</td><td>\(set.summary)</td></tr>"
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>cmux-next status icon candidates</title>
        <style>body{font:13px -apple-system,system-ui,sans-serif;background:#1d1f21;color:#c5c8c6;margin:24px}
        h2{margin-top:32px}figure{margin:0 16px 12px 0}figcaption{color:#969896;font-size:11px}.pair{display:flex;flex-wrap:wrap;align-items:flex-start}
        img{display:block;border-radius:6px}table{border-collapse:collapse}td{padding:4px 10px;border-bottom:1px solid #373b41;vertical-align:top}code{color:#b5bd68}</style></head><body>
        <h1>Status icon candidates (cx-kxa2)</h1>
        <p>Rendered by the app's own StatusIndicatorLayer and SidebarView, frames from the Core Animation compositor (CARenderer), 2x pixels shown at real size.
        Blocked kinds come from OSC 7501 <code>kind</code> (permission, question, auth). Colors are the theme's attention, danger, success and foreground roles.
        Pick one in DEV/NIGHTLY: Debug menu &gt; Status Icons, or Debug Settings &gt; Status Indicators &gt; Status icons. The default stays <code>current</code> until one is picked.</p>
        <table>\(legend)</table>
        \(body)
        </body></html>
        """
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = package.appending(path: ".build/status-icons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: folder.appending(path: "contact-sheet.html"))
        if let artifacts = ProcessInfo.processInfo.environment["NX_ARTIFACTS"] {
            try Data(html.utf8).write(to: URL(fileURLWithPath: artifacts).appending(path: "status-icons-contact-sheet.html"))
        }
        #expect(anyMotion, "the compositor renders the working animations")
        #expect(html.contains("badges"))
    }
}
