import CoreGraphics
import CoreText
import Foundation

/// The synthetic desktop the demo server shows: a static backdrop, a paint
/// layer the pointer draws on, a bouncing tile (motion), and a status window
/// that echoes typed text and the last key. Renders into a BGRX framebuffer
/// and reports what changed.
final class DemoScene {
    let width: Int
    let height: Int
    /// `0xAARRGGBB` words, bytes `B G R A` in memory; `output` draws here.
    private let storage: UnsafeMutablePointer<UInt32>
    var pixels: UnsafeBufferPointer<UInt32> { UnsafeBufferPointer(start: storage, count: width * height) }
    private var backdrop: CGImage?
    private let paint: CGContext
    private let output: CGContext
    private var tile = CGRect(x: 120, y: 160, width: 96, height: 96)
    private var velocity = CGPoint(x: 7, y: 5)
    private(set) var typed = ""
    private var lastKey = "none"
    private var frameCount = 0
    private var lastStroke: CGPoint?
    /// The paint layer as an image, rebuilt only after a stroke.
    private var painted: CGImage?
    var clients = 0
    var animate: Bool

    /// Nil when Core Graphics cannot make the bitmap contexts (a size it refuses).
    init?(width: Int, height: Int, animate: Bool) {
        self.width = width
        self.height = height
        self.animate = animate
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let paint = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: info) else { return nil }
        let storage = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        storage.initialize(repeating: 0xFF00_0000, count: width * height)
        guard let output = CGContext(data: storage, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: info) else {
            storage.deinitialize(count: width * height)
            storage.deallocate()
            return nil
        }
        self.storage = storage
        self.paint = paint
        self.output = output
        // Flip both contexts so y grows downward like the framebuffer.
        for context in [paint, output] {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        backdrop = Self.makeBackdrop(width: width, height: height)
        render(CGRect(x: 0, y: 0, width: width, height: height))
    }

    deinit {
        storage.deinitialize(count: width * height)
        storage.deallocate()
    }

    var statusRect: CGRect { CGRect(x: 40, y: 40, width: min(560, CGFloat(width) - 80), height: 220) }

    /// Advances the animation one step; returns what changed.
    func tick() -> CGRect {
        frameCount += 1
        var dirty = statusRect
        guard animate else { render(dirty); return dirty }
        let old = tile
        tile.origin.x += velocity.x
        tile.origin.y += velocity.y
        if tile.minX < 0 || tile.maxX > CGFloat(width) { velocity.x = -velocity.x; tile.origin.x += 2 * velocity.x }
        if tile.minY < 0 || tile.maxY > CGFloat(height) { velocity.y = -velocity.y; tile.origin.y += 2 * velocity.y }
        dirty = dirty.union(old).union(tile)
        render(old.union(tile))
        render(statusRect)
        return dirty.integral
    }

    func key(_ keysym: UInt32, down: Bool, shift: Bool) -> CGRect {
        guard down else { return .null }
        lastKey = String(format: "0x%04X", keysym)
        switch keysym {
        case 0xFF08: if !typed.isEmpty { typed.removeLast() }
        case 0xFF0D: typed.append("\n")
        case 0x20 ... 0xFF:
            var character = Character(Unicode.Scalar(UInt8(keysym)))
            if shift, character.isLetter { character = Character(character.uppercased()) }
            typed.append(character)
        case 0x0100_0000 ... 0x0110_FFFF:
            if let scalar = Unicode.Scalar(keysym & 0x00FF_FFFF) { typed.append(Character(scalar)) }
        default:
            break
        }
        if typed.count > 400 { typed.removeFirst(typed.count - 400) }
        render(statusRect)
        return statusRect
    }

    /// Left-button drags paint strokes on the paint layer.
    func pointer(x: Int, y: Int, leftDown: Bool) -> CGRect {
        let point = CGPoint(x: x, y: y)
        defer { lastStroke = leftDown ? point : nil }
        guard leftDown else { return .null }
        let from = lastStroke ?? point
        paint.setStrokeColor(CGColor(red: 1, green: 0.78, blue: 0.2, alpha: 1))
        paint.setLineWidth(6)
        paint.setLineCap(.round)
        paint.move(to: from)
        paint.addLine(to: point)
        paint.strokePath()
        painted = nil
        let dirty = CGRect(x: min(from.x, point.x) - 6, y: min(from.y, point.y) - 6,
                           width: abs(from.x - point.x) + 12, height: abs(from.y - point.y) + 12).integral
        render(dirty)
        return dirty
    }

    /// Redraws `rect` from the layers into `pixels`.
    private func render(_ rect: CGRect) {
        let clip = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clip.isNull, !clip.isEmpty else { return }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        output.saveGState()
        output.clip(to: clip)
        if let backdrop { drawImage(backdrop, in: full) }
        if painted == nil { painted = paint.makeImage() }
        if let painted { drawImage(painted, in: full) }
        output.setFillColor(CGColor(red: 0.33, green: 0.55, blue: 1, alpha: 1))
        output.fill(tile)
        output.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        output.fill(tile.insetBy(dx: 30, dy: 30))
        drawStatus()
        output.restoreGState()
    }

    /// Images draw upright in the flipped context.
    private func drawImage(_ image: CGImage, in rect: CGRect) {
        output.saveGState()
        output.translateBy(x: 0, y: rect.maxY)
        output.scaleBy(x: 1, y: -1)
        output.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        output.restoreGState()
    }

    private func drawStatus() {
        let box = statusRect
        output.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 0.92))
        output.addPath(CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil))
        output.fillPath()
        let time = Date().formatted(date: .omitted, time: .standard)
        let tail = typed.split(separator: "\n", omittingEmptySubsequences: false).suffix(4).joined(separator: "\n")
        let lines = [
            ("cmux VNC demo desktop", 20.0, true),
            ("\(width)x\(height) · frame \(frameCount) · \(time) · viewers \(clients)", 13.0, false),
            ("Drag to paint. Type to echo below. Last key \(lastKey).", 13.0, false),
            ("> " + tail, 15.0, false),
        ]
        var y = box.minY + 18
        for (text, size, bold) in lines {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                drawText(String(line), at: CGPoint(x: box.minX + 18, y: y), size: size, bold: bold)
                y += size + 9
            }
        }
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, bold: Bool) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Menlo-Regular") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.92, green: 0.94, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        output.saveGState()
        // Text draws upright: undo the flip around the baseline.
        output.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        output.textPosition = CGPoint(x: point.x, y: point.y + size)
        CTLineDraw(line, output)
        output.restoreGState()
    }

    private static func makeBackdrop(width: Int, height: Int) -> CGImage? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        let colors = [CGColor(red: 0.10, green: 0.12, blue: 0.28, alpha: 1), CGColor(red: 0.42, green: 0.18, blue: 0.46, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
        for x in stride(from: 0, to: width, by: 32) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, to: height, by: 32) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
        return context.makeImage()
    }
}
