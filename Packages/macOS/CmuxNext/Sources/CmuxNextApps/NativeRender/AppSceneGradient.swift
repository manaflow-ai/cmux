import AppKit

/// A scene gradient fill (`background` on any node, `fill` on a shape): `{linear: {colors, angle?}}`
/// or `{radial: {colors}}`, 2 to 8 stops that are each a tone or `#RRGGBB[AA]`, spaced evenly.
/// `angle` is in degrees the CSS way: 0 points up, 90 right, 180 (the default) down. Anything else
/// parses to nil, so a bad value draws no fill. Colors resolve in the view's theme scope.
struct AppSceneGradient {
    enum Kind {
        case linear(angle: Double)
        case radial
    }

    let kind: Kind
    let colors: [NSColor]

    /// The gradient a prop value names, or nil when it is not a valid gradient.
    @MainActor
    init?(_ value: AppJSON?) {
        guard let record = value?.objectValue, record.count == 1, let entry = record.first,
              let spec = entry.value.objectValue else { return nil }
        let name = entry.key
        let allowed: Set<String> = name == "linear" ? ["colors", "angle"] : ["colors"]
        guard name == "linear" || name == "radial", Set(spec.keys).isSubset(of: allowed),
              let stops = spec["colors"]?.arrayValue, (2...8).contains(stops.count) else { return nil }
        let colors = stops.compactMap(\.sceneColor)
        guard colors.count == stops.count else { return nil }
        if name == "radial" {
            kind = .radial
        } else {
            switch spec["angle"] {
            case nil: kind = .linear(angle: 180)
            case .number(let degrees)? where degrees.isFinite: kind = .linear(angle: degrees)
            default: return nil
            }
        }
        self.colors = colors
    }

    /// Points `layer` at this gradient over a box of `size` (CSS geometry: the line through the center
    /// at `angle`, long enough that the corners reach the first and last stops). `yDown` is whether
    /// the layer's unit space runs top to bottom.
    func apply(to layer: CAGradientLayer, size: CGSize, yDown: Bool) {
        layer.colors = colors.map(\.cgColor)
        layer.locations = nil
        switch kind {
        case .radial:
            layer.type = .radial
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1, y: 1)
        case .linear(let angle):
            layer.type = .axial
            let radians = angle * .pi / 180
            let (sx, cy) = (sin(radians), cos(radians))
            let length = abs(size.width * sx) + abs(size.height * cy)
            // Half the gradient line, in unit coordinates of a y-down box.
            let dx = size.width > 0 ? sx * length / 2 / size.width : 0
            var dy = size.height > 0 ? -cy * length / 2 / size.height : 0
            if !yDown { dy = -dy }
            layer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
            layer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        }
    }
}
