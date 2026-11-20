#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextSettings
import ImageIO

/// The overlay measure of the Liquid Glass Parity playground: each renderer alone over the same backdrop,
/// captured at the same frame, and each web renderer's pixels diffed against the native ones.
extension GlassParityPlayground {
    /// A crop's RGBA8 pixels.
    typealias Pixels = (bytes: [UInt8], width: Int, height: Int)

    /// One surface's box in the capture's pixels (the surface and a margin, so its shadow and rim are in
    /// the diff), and its text inside that box.
    nonisolated struct CellBox: Sendable {
        var kind: String
        var box: CGRect
        var text: CGRect
    }

    /// The scenario's file stem with what the App sets (appearance, Reduce Transparency, Increase
    /// Contrast) and the backing scale.
    var measureStem: String {
        guard let window else { return scenario.stem }
        var parts = [scenario.stem, appearance]
        if ReduceTransparency.shared.isEnabled { parts.append("rt") }
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast { parts.append("ic") }
        parts.append("\(Int(window.backingScaleFactor))x")
        return parts.joined(separator: "-")
    }

    /// The most captures of one renderer while its glass still eases to the backdrop (about 2.4 s).
    static let maximumCaptures = 6

    /// The stage's pixels in the capture at `url`, to tell whether two captures are the same.
    nonisolated static func stagePixels(_ url: URL, _ stage: CGRect) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return GlassParityDiff.pixels(of: image, in: stage)?.bytes
    }

    /// Captures every renderer alone into `directory` through `capture` (`debug.window_snapshot`
    /// params: the window and a PNG path) and answers each web surface's diff against the native one at
    /// the same box, with its text (`full`) and without (`material`). Writes per surface each renderer's
    /// crop, the onion skin and the difference, and the whole window's onion skin and difference.
    public func measure(into directory: URL, capture: ([String: JSONValue]) async -> JSONValue) async -> JSONValue {
        guard let window, let content = window.contentView else { return ["error": "the playground is not open"] }
        let stem = measureStem
        await Task.detached(priority: .utility) { try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true) }.value
        var shots: [String: URL] = [:]
        var snapshots: [String: JSONValue] = [:]
        // The capture is the window's frame at its backing scale, title bar on top, no shadow.
        let scale = window.backingScaleFactor
        let contentInWindow = content.convert(content.bounds, to: nil)
        let contentTop = (window.frame.height - contentInWindow.maxY) * scale
        let stage = CGRect(x: 0, y: contentTop, width: Self.contentSize.width * scale, height: Self.contentSize.height * scale)
        for column in Column.allCases where column == .native || pages[column] != nil {
            solo(column)
            await settle()
            let png = directory.appending(path: "window-\(stem)-\(column.rawValue).png", directoryHint: .notDirectory)
            // Captured until two captures in a row are the same: Liquid Glass eases its adaptive look to a new backdrop
            // over more than a second, and a hidden glass view does not ease at all, so the renderer shown first
            // (native) still carried the last scenario's look over a dark picture (fleet run b44f5987: the tooltip's
            // glass 46 levels darker than the same glass under the page, every web column alike).
            var previous: [UInt8]?
            var reply: JSONValue = .null
            var captures = 0
            var keyAtCapture = true
            while captures < Self.maximumCaptures {
                captures += 1
                // An active cell is the key window's glass: in an active app whose key window is another one, the
                // glass's key look (ActiveLookScope) holds only through its own updates, so two glass views drifted
                // apart by when each last updated (fleet step 8bf3dbb6: every failing tooltip cell, none other).
                // The app's main window may take key at any time after activation; take it back before each capture.
                if scenario.active, !window.isKeyWindow {
                    window.makeKeyAndOrderFront(nil)
                    await settle()
                }
                keyAtCapture = keyAtCapture && (!scenario.active || window.isKeyWindow)
                // `chromium_pages: false`: the window server's composite already holds the Chromium page (its child
                // window); painting Chromium's own image over it again drew its text and row fills twice.
                reply = await capture(["window": .string(String(window.windowNumber)), "path": .string(png.path),
                                       "chromium_pages": .bool(false)])
                let now = await Task.detached(priority: .utility) { Self.stagePixels(png, stage) }.value
                if let now, now == previous { break }
                previous = now
                await wait(until: { false }, limit: .milliseconds(400))
            }
            if case .object(var members) = reply {
                members["captures"] = .number(Double(captures))
                members["key"] = .bool(window.isKeyWindow)
                members["key_at_capture"] = .bool(keyAtCapture)
                reply = .object(members)
            }
            snapshots[column.rawValue] = reply
            shots[column.rawValue] = png
        }
        solo(nil)
        let cells = Kind.allCases.map { kind -> CellBox in
            let surface = Self.surfaceRect(kind)
            let box = surface.insetBy(dx: -8, dy: -8)
            let text = CGRect(x: (surface.minX - box.minX + Self.textInset.left) * scale,
                              y: (surface.minY - box.minY + Self.textInset.top) * scale,
                              width: (surface.width - Self.textInset.left - Self.textInset.right) * scale,
                              height: Self.textHeight * scale)
            return CellBox(kind: kind.rawValue,
                           box: CGRect(x: box.minX * scale, y: contentTop + box.minY * scale, width: box.width * scale, height: box.height * scale),
                           text: text)
        }
        let report = await Task.detached(priority: .utility) {
            Self.diffOverlay(shots: shots, directory: directory, stem: stem, cells: cells, stage: stage)
        }.value
        guard case .object(var members) = report else { return report }
        members["status"] = status()
        members["snapshots"] = .object(snapshots)
        var probes: [String: JSONValue] = [:]
        for (column, page) in pages { probes[column.rawValue] = await Self.probe(page) }
        members["probe"] = .object(probes)
        // The tooltip's native glass beside each column's host glass under the web tooltip (their pixels differ by
        // backdrop: fleet steps 368e35ec, 339c069f).
        var trees: [String: JSONValue] = [:]
        if let native = nativeLayer?.subviews.first(where: { $0.frame == Self.surfaceRect(.tooltip) }) { trees["native"] = glassParityTree(native) }
        for (column, host) in hosts { if let view = host.tooltipSurface { trees[column.rawValue] = glassParityTree(view) } }
        members["tooltip_tree"] = .object(trees)
        return .object(members)
    }

    /// What each web surface draws itself (its computed fill, filters, edge and veil), so a residual
    /// names its CSS: read from the page in either engine.
    static func probe(_ page: PageWebView) async -> JSONValue {
        let script = """
        const pick = (s) => ({ bg: s.backgroundColor, image: s.backgroundImage.slice(0, 160),
          backdrop: s.backdropFilter || s.webkitBackdropFilter || '', filter: s.filter, shadow: s.boxShadow.slice(0, 160),
          border: s.borderTopWidth + ' ' + s.borderTopStyle + ' ' + s.borderTopColor, opacity: s.opacity, radius: s.borderTopLeftRadius });
        const box = (e) => { const r = e.getBoundingClientRect(); return [r.left, r.top, r.width, r.height].map((v) => Math.round(v * 100) / 100); };
        const text = (e) => e && (({ color, fontFamily, fontSize, fontWeight, lineHeight, webkitFontSmoothing }) =>
          ({ color, fontFamily: fontFamily.slice(0, 80), fontSize, fontWeight, lineHeight, smoothing: webkitFontSmoothing, box: box(e) }))(getComputedStyle(e));
        const vars = getComputedStyle(document.documentElement);
        return JSON.stringify({ root: Object.assign({}, document.documentElement.dataset), dpr: devicePixelRatio,
          viewport: [innerWidth, innerHeight, visualViewport ? visualViewport.offsetTop : -1, visualViewport ? visualViewport.height : -1, document.documentElement.clientHeight],
          vars: Object.fromEntries(['--cmux-text', '--cmux-text-secondary', '--cmux-hover', '--cmux-pressed', '--cmux-row-focus']
            .map((name) => [name, vars.getPropertyValue(name).trim()])),
          cells: [...document.querySelectorAll('.glass-parity-surface')].map((e) => ({ kind: e.dataset.parityKind,
            drawn: e.getAttribute('data-host-glass-drawn'), self: pick(getComputedStyle(e)), box: box(e),
            before: pick(getComputedStyle(e, '::before')), after: pick(getComputedStyle(e, '::after')),
            title: text(e.querySelector('.glass-parity-title')), detail: text(e.querySelector('.glass-parity-detail')),
            row: e.querySelector('.glass-parity-row') && { ...pick(getComputedStyle(e.querySelector('.glass-parity-row'))),
              box: box(e.querySelector('.glass-parity-row')), uiRow: getComputedStyle(e.querySelector('.glass-parity-row')).getPropertyValue('--ui-row').trim() } })) });
        """
        guard let text = await page.callPageFunction(script) as? String, let value = try? JSONValue.parse(Data(text.utf8)) else {
            return .null
        }
        return value
    }

    /// Reads each renderer's capture, crops every surface, writes the crops, onion skins and differences,
    /// and diffs each web renderer against the native one (off the main actor).
    nonisolated static func diffOverlay(shots: [String: URL], directory: URL, stem: String, cells: [CellBox], stage: CGRect) -> JSONValue {
        var images: [String: CGImage] = [:]
        for (column, url) in shots {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            images[column] = image
        }
        guard let nativeImage = images[Column.native.rawValue] else { return ["error": "no native capture"] }
        let webColumns = [Column.webkit.rawValue, Column.chromium.rawValue].filter { images[$0] != nil }
        func file(_ name: String) -> URL { directory.appending(path: name, directoryHint: .notDirectory) }
        var out: [String: JSONValue] = [:]
        var windows: [String: JSONValue] = [:]
        // The whole stage, onion skin and difference, per web renderer.
        if let native = GlassParityDiff.pixels(of: nativeImage, in: stage) {
            for column in webColumns {
                guard let image = images[column], let web = GlassParityDiff.pixels(of: image, in: stage),
                      web.width == native.width, web.height == native.height else { continue }
                writePNG(onion(native, web), to: file("window-\(stem)-\(column)-onion.png"))
                writeDiffPNG(native, web, to: file("window-\(stem)-\(column)-diff.png"))
                windows[column] = GlassParityDiff.compare(native.bytes, web.bytes, width: web.width, height: web.height,
                                                          bytesPerRow: web.width * 4).map(json) ?? .null
            }
        }
        for cell in cells {
            guard let native = GlassParityDiff.pixels(of: nativeImage, in: cell.box) else { continue }
            writePNG(native, to: file("\(cell.kind)-native-\(stem).png"))
            var row: [String: JSONValue] = [:]
            for column in webColumns {
                guard let image = images[column], let web = GlassParityDiff.pixels(of: image, in: cell.box),
                      web.width == native.width, web.height == native.height else { continue }
                writePNG(web, to: file("\(cell.kind)-\(column)-\(stem).png"))
                writePNG(onion(native, web), to: file("\(cell.kind)-\(column)-onion-\(stem).png"))
                writeDiffPNG(native, web, to: file("\(cell.kind)-\(column)-diff-\(stem).png"))
                let full = GlassParityDiff.compare(native.bytes, web.bytes, width: web.width, height: web.height, bytesPerRow: web.width * 4)
                let material = GlassParityDiff.compare(native.bytes, web.bytes, width: web.width, height: web.height,
                                                       bytesPerRow: web.width * 4, excluded: [cell.text])
                row[column] = ["full": full.map(json) ?? .null, "material": material.map(json) ?? .null]
            }
            out[cell.kind] = .object(row)
        }
        return [
            "stem": .string(stem), "cells": .object(out), "window": .object(windows),
            "image_width": .number(Double(nativeImage.width)),
            "tolerance": ["mean": .number(GlassParityDiff.hostTolerance.mean), "p99": .number(Double(GlassParityDiff.hostTolerance.p99))],
        ]
    }

    private nonisolated static func json(_ diff: GlassParityDiff) -> JSONValue {
        .object(diff.json.mapValues(JSONValue.number))
    }

    /// The web pixels over the native ones at half opacity: where they match, the onion skin is the
    /// native image; where they do not, both show, offset edges doubled.
    nonisolated static func onion(_ a: Pixels, _ b: Pixels) -> Pixels {
        var bytes = a.bytes
        for i in bytes.indices { bytes[i] = UInt8((Int(a.bytes[i]) + Int(b.bytes[i]) + 1) / 2) }
        return (bytes, a.width, a.height)
    }

    private nonisolated static func image(_ crop: Pixels) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(crop.bytes) as CFData) else { return nil }
        return CGImage(width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: crop.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private nonisolated static func writePNG(_ crop: Pixels, to url: URL) {
        guard let image = image(crop),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The per-pixel error as a heat image (a difference blend, amplified): black where equal, brighter
    /// with the error (x8, so a step of 32 is white).
    private nonisolated static func writeDiffPNG(_ a: Pixels, _ b: Pixels, to url: URL) {
        var bytes = [UInt8](repeating: 255, count: a.bytes.count)
        for i in stride(from: 0, to: a.bytes.count, by: 4) {
            let error = Swift.max(abs(Int(a.bytes[i]) - Int(b.bytes[i])), abs(Int(a.bytes[i + 1]) - Int(b.bytes[i + 1])),
                                  abs(Int(a.bytes[i + 2]) - Int(b.bytes[i + 2])))
            let value = UInt8(Swift.min(255, error * 8))
            bytes[i] = value
            bytes[i + 1] = value
            bytes[i + 2] = value
        }
        writePNG((bytes, a.width, a.height), to: url)
    }
}
#endif
