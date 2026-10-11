public import CoreGraphics

/// A pack layer fitted to the device pixel grid: its path in grid units and
/// its stroke width rounded to whole device pixels.
public nonisolated struct FittedIconLayer {
    public var layer: IconLayer
    public var path: CGPath
    public var width: CGFloat
}

/// Fits pack drawings to the device pixels they land on, so a 16 pt icon's
/// strokes are solid pixel columns at 1x and 2x instead of half-inked pairs.
///
/// Stroke widths round to whole pixels. Horizontal and vertical lines snap to
/// pixel centers (odd widths) or edges (even widths and fills), and the
/// points between them follow by interpolation so shapes stay joined. Closed
/// curve-only subpaths (circles, ovals) move and scale as a whole, by the
/// same factor on both axes when round, so they stay round.
public nonisolated struct IconPixelGrid {
    /// Grid units to device pixels.
    let toDevice: CGAffineTransform
    private let fromDevice: CGAffineTransform
    private let scale: CGFloat

    /// Nil for a rotated, skewed or unevenly scaled transform, which draws unfitted.
    public init?(toDevice: CGAffineTransform) {
        let sx = abs(toDevice.a), sy = abs(toDevice.d)
        guard abs(toDevice.b) < 1e-6, abs(toDevice.c) < 1e-6, sx > 0, sy > 0,
              abs(sx - sy) <= 1e-3 * max(sx, sy) else { return nil }
        self.toDevice = toDevice
        fromDevice = toDevice.inverted()
        scale = (sx + sy) / 2
    }

    /// `layers` with paths and widths fitted to this grid; unparseable layers drop out.
    public static func fit(_ layers: [IconLayer], toDevice: CGAffineTransform) -> [FittedIconLayer] {
        if let grid = IconPixelGrid(toDevice: toDevice) {
            return grid.fit(layers)
        }
        return layers.compactMap { layer in
            CGPath.icon(layer.d).map { FittedIconLayer(layer: layer, path: $0, width: layer.width) }
        }
    }

    func fit(_ layers: [IconLayer]) -> [FittedIconLayer] {
        let parsed = layers.compactMap { layer in
            CGPath.icon(layer.d).map { (layer, Subpath.split($0.copy(using: [toDevice]) ?? $0)) }
        }
        // Shapes center on the grid of the icon's first ink stroke, so a
        // ring and the cross inside it share one center.
        let center = parsed.first { $0.0.op == .stroke }.map { phase(of: $0.0) } ?? 0
        var xStems: [CGFloat: CGFloat] = [:], yStems: [CGFloat: CGFloat] = [:]
        for (layer, subpaths) in parsed {
            let edge = phase(of: layer)
            for subpath in subpaths where !subpath.isClosedCurve {
                subpath.stems(x: &xStems, y: &yStems, snap: { Self.snap($0, phase: edge) })
            }
        }
        let mapX = Axis(stems: xStems), mapY = Axis(stems: yStems)
        return parsed.map { layer, subpaths in
            let edge = phase(of: layer)
            let path = CGMutablePath()
            for subpath in subpaths {
                let move: (CGPoint) -> CGPoint
                if subpath.isClosedCurve {
                    move = subpath.shapeFit(edge: edge, center: center)
                } else {
                    move = { CGPoint(x: mapX($0.x), y: mapY($0.y)) }
                }
                subpath.add(to: path, moving: { move($0).applying(fromDevice) })
            }
            let width = layer.op.strokes ? CGFloat(pixels(layer.width)) / scale : layer.width
            return FittedIconLayer(layer: layer, path: path, width: width)
        }
    }

    /// Device pixels a stroke covers, at least one.
    private func pixels(_ width: CGFloat) -> Int {
        max(1, Int((width * scale).rounded()))
    }

    /// Where `layer`'s edges sit within a pixel: 0.5 for an odd-width stroke
    /// (its center is on a pixel center), 0 otherwise.
    private func phase(of layer: IconLayer) -> CGFloat {
        layer.op.strokes && !pixels(layer.width).isMultiple(of: 2) ? 0.5 : 0
    }

    /// The nearest point on the `phase` grid. Centered geometry often sits
    /// exactly between two pixels, so the offset is quantized first (grid 12
    /// at 16 pt is 7.9999… for one path and 8.0000… for another) and ties
    /// always go up.
    static func snap(_ value: CGFloat, phase: CGFloat) -> CGFloat {
        let offset = ((value - phase) * 1024).rounded() / 1024
        return (offset + 0.5).rounded(.down) + phase
    }

    /// A piecewise-linear remap of one axis through its snapped stems.
    private nonisolated struct Axis {
        let stems: [(from: CGFloat, to: CGFloat)]

        init(stems: [CGFloat: CGFloat]) {
            self.stems = stems.sorted { $0.key < $1.key }.map { (from: $0.key, to: $0.value) }
        }

        func callAsFunction(_ value: CGFloat) -> CGFloat {
            guard let first = stems.first, let last = stems.last else { return value }
            if value <= first.from { return value + first.to - first.from }
            for (low, high) in zip(stems, stems.dropFirst()) where value <= high.from {
                let t = (value - low.from) / (high.from - low.from)
                return low.to + t * (high.to - low.to)
            }
            return value + last.to - last.from
        }
    }
}

/// One subpath of a device-space path.
private nonisolated struct Subpath {
    nonisolated enum Element {
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
    }

    var start: CGPoint
    var elements: [Element] = []
    var closed = false

    private static let epsilon: CGFloat = 1e-3

    static func split(_ path: CGPath) -> [Subpath] {
        var subpaths: [Subpath] = []
        var current: CGPoint = .zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                subpaths.append(Subpath(start: points[0]))
                current = points[0]
            case .addLineToPoint:
                subpaths[subpaths.count - 1].elements.append(.line(points[0]))
                current = points[0]
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: current.x + 2 / 3 * (points[0].x - current.x), y: current.y + 2 / 3 * (points[0].y - current.y))
                let c2 = CGPoint(x: points[1].x + 2 / 3 * (points[0].x - points[1].x), y: points[1].y + 2 / 3 * (points[0].y - points[1].y))
                subpaths[subpaths.count - 1].elements.append(.curve(c1, c2, points[1]))
                current = points[1]
            case .addCurveToPoint:
                subpaths[subpaths.count - 1].elements.append(.curve(points[0], points[1], points[2]))
                current = points[2]
            case .closeSubpath:
                subpaths[subpaths.count - 1].closed = true
                current = subpaths[subpaths.count - 1].start
            @unknown default:
                break
            }
        }
        return subpaths
    }

    /// The straight segments, including the closing one.
    private var segments: [(CGPoint, CGPoint)] {
        var result: [(CGPoint, CGPoint)] = []
        var current = start
        for element in elements {
            switch element {
            case .line(let point):
                result.append((current, point))
                current = point
            case .curve(_, _, let point):
                current = point
            }
        }
        if closed { result.append((current, start)) }
        return result
    }

    private var end: CGPoint {
        switch elements.last {
        case .line(let point)?, .curve(_, _, let point)?: point
        case nil: start
        }
    }

    /// A closed shape drawn only with curves: a circle or oval.
    var isClosedCurve: Bool {
        let curves = elements.contains { if case .curve = $0 { true } else { false } }
        let straight = segments.contains { hypot($1.x - $0.x, $1.y - $0.y) > Self.epsilon }
        let ends = hypot(end.x - start.x, end.y - start.y) <= Self.epsilon
        return curves && !straight && (closed || ends)
    }

    /// Records the snapped position of each horizontal and vertical line.
    func stems(x: inout [CGFloat: CGFloat], y: inout [CGFloat: CGFloat], snap: (CGFloat) -> CGFloat) {
        for (a, b) in segments {
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            if dx <= Self.epsilon, dy > Self.epsilon, x[a.x] == nil {
                x[a.x] = snap(a.x)
            } else if dy <= Self.epsilon, dx > Self.epsilon, y[a.y] == nil {
                y[a.y] = snap(a.y)
            }
        }
    }

    /// Moves and scales this shape so its edges land on `edge` and its
    /// center on `center`; a round shape scales evenly on both axes.
    func shapeFit(edge: CGFloat, center: CGFloat) -> (CGPoint) -> CGPoint {
        let path = CGMutablePath()
        add(to: path, moving: { $0 })
        let box = path.boundingBoxOfPath
        // Both edges on `edge` and the center on `center` takes a span whose
        // parity matches twice their offset.
        let odd = !(2 * abs(edge - center)).rounded().truncatingRemainder(dividingBy: 2).isZero
        func span(_ length: CGFloat) -> CGFloat {
            let even = max(2, 2 * (length / 2).rounded())
            let oddSpan = max(1, 2 * ((length - 1) / 2).rounded() + 1)
            return odd ? oddSpan : even
        }
        let width = span(box.width)
        let height = abs(box.width - box.height) <= Self.epsilon ? width : span(box.height)
        let cx = IconPixelGrid.snap(box.midX, phase: center), cy = IconPixelGrid.snap(box.midY, phase: center)
        let sx = box.width > 0 ? width / box.width : 1, sy = box.height > 0 ? height / box.height : 1
        return { CGPoint(x: cx + ($0.x - box.midX) * sx, y: cy + ($0.y - box.midY) * sy) }
    }

    func add(to path: CGMutablePath, moving move: (CGPoint) -> CGPoint) {
        path.move(to: move(start))
        for element in elements {
            switch element {
            case .line(let point):
                path.addLine(to: move(point))
            case .curve(let c1, let c2, let point):
                path.addCurve(to: move(point), control1: move(c1), control2: move(c2))
            }
        }
        if closed { path.closeSubpath() }
    }
}
