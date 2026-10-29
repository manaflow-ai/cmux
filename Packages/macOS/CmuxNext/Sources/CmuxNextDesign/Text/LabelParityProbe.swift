#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

/// `debug.label_parity` (DEBUG; text-weight-e2e.py, cx-8w027.26): ``ChromeLabel`` next to a stock
/// `NSTextField` label with the same settings, over the settings the app uses (factory, font,
/// text, line count, line break, preferred width, frame width).
///
/// Each pair is checked for what moves a layout or what VoiceOver reads: the intrinsic size, the
/// first and last baselines, the ink of the text in the same frame (its bounding box and amount,
/// drawn through `cacheDisplay` as a drag image is), the layer drawing (`CALayer.render(in:)`,
/// the other drag image path) and the accessibility role and value.
public struct LabelParityProbe {
    /// Where the images of the first pairs whose ink differs go (nil: none written).
    public let imageDirectory: URL?

    public init(imageDirectory: URL? = nil) { self.imageDirectory = imageDirectory }

    public struct Report: Sendable {
        public var checked = 0
        public var mismatches: [String] = []
        public var mismatchCount = 0
        /// Every value of each pair (the first 2000 pairs).
        public var rows: [[String: String]] = []
        public var imagesWritten = 0

        /// The report as JSON objects (the debug socket's answer).
        public var foundation: [String: Any] {
            ["checked": checked, "mismatch_count": mismatchCount, "mismatches": mismatches, "rows": rows]
        }
    }

    private enum Factory: String, CaseIterable { case label, wrapping, font }

    private static let texts = ["", "Hi", "Workspace notes 0123 quick brown fox jumps over the lazy dog again",
                                "line one\nline two is longer",
                                // Spaces before a line break, right-to-left text that wraps (a fallback font), cx-8w027.26.1.
                                "short   \nthe next line of this label is longer",
                                "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD} \u{05D6}\u{05D4}\u{05D5} \u{05D8}\u{05E7}\u{05E1}\u{05D8} \u{05D0}\u{05E8}\u{05D5}\u{05DA} \u{05DE}\u{05D0}\u{05D5}\u{05D3} \u{05DC}\u{05D1}\u{05D3}\u{05D9}\u{05E7}\u{05D4} \u{05E9}\u{05DC} \u{05EA}\u{05D5}\u{05D5}\u{05D9}\u{05D5}\u{05EA}",
                                // Fallback fonts in a Latin line (emoji, CJK).
                                "Deploy \u{1F680} build \u{2705} done \u{6F22}\u{5B57} notes"]
    private static let fonts: [(String, NSFont)] = [
        ("13r", .systemFont(ofSize: TypeScale.body)), ("11r", .systemFont(ofSize: TypeScale.caption)),
        ("12m", .systemFont(ofSize: TypeScale.detail, weight: .medium)),
        ("10.5r", .systemFont(ofSize: 10.5)),
    ]
    private static let lineCounts: [Int?] = [nil, 1, 2, 0]
    /// nil: the factory's; `wrapsTruncating`: a truncating mode, then wrapping turned on (a
    /// wrapped text whose last line truncates).
    private static let lineBreaks: [NSLineBreakMode?] = [nil, .byTruncatingTail, .byWordWrapping, wrapsTruncating]
    private static let wrapsTruncating = NSLineBreakMode.byTruncatingMiddle
    private static let preferredWidths: [CGFloat] = [0, 140]
    private static let widths: [CGFloat] = [70, 220]

    public func measure() -> Report {
        var report = Report()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        root.wantsLayer = true
        window.contentView = root
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for factory in Factory.allCases {
            for (fontName, font) in Self.fonts {
                for (textIndex, text) in Self.texts.enumerated() {
                    for lines in Self.lineCounts {
                        for lineBreak in Self.lineBreaks {
                            for preferred in Self.preferredWidths {
                                let name = "\(factory.rawValue) \(fontName) t\(textIndex) lines=\(lines.map(String.init) ?? "-") "
                                    + "lb=\(lineBreak.map { "\($0.rawValue)" } ?? "-") pmlw=\(Int(preferred))"
                                let stock = Self.stock(factory, text: text, font: font)
                                let label = Self.chrome(factory, text: text, font: font)
                                if let lines { stock.maximumNumberOfLines = lines; label.maximumNumberOfLines = lines }
                                if lineBreak == Self.wrapsTruncating {
                                    stock.lineBreakMode = .byTruncatingTail
                                    stock.cell?.wraps = true
                                    label.lineBreakMode = .byTruncatingTail
                                    label.wraps = true
                                } else if let lineBreak {
                                    stock.lineBreakMode = lineBreak
                                    label.lineBreakMode = lineBreak
                                }
                                stock.preferredMaxLayoutWidth = preferred
                                label.preferredMaxLayoutWidth = preferred
                                stock.textColor = .black
                                label.textColor = .black
                                compare(stock, label, name: name, in: root, into: &report)
                            }
                        }
                    }
                }
            }
        }
        return report
    }

    private static func stock(_ factory: Factory, text: String, font: NSFont) -> NSTextField {
        switch factory {
        case .label: let field = NSTextField(labelWithString: text); field.font = font; return field
        case .wrapping: let field = NSTextField(wrappingLabelWithString: text); field.font = font; return field
        case .font:
            // ChromeLabel(font:)'s settings on a stock label.
            let field = NSTextField(labelWithString: "")
            field.font = font
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
            field.stringValue = text
            return field
        }
    }

    private static func chrome(_ factory: Factory, text: String, font: NSFont) -> ChromeLabel {
        switch factory {
        case .label: let label = ChromeLabel(labelWithString: text); label.font = font; return label
        case .wrapping: let label = ChromeLabel(wrappingLabelWithString: text); label.font = font; return label
        case .font: let label = ChromeLabel(font: font); label.stringValue = text; return label
        }
    }

    private func compare(_ stock: NSTextField, _ label: ChromeLabel, name: String, in root: NSView, into report: inout Report) {
        var row: [String: String] = ["name": name]
        func differ(_ what: String, _ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.01) {
            report.checked += 1
            row["\(what).stock"] = "\(a)"
            row["\(what).label"] = "\(b)"
            guard abs(a - b) > tolerance else { return }
            note("\(name) \(what): stock \(a) label \(b)", into: &report)
        }
        defer { if report.rows.count < 2000 { report.rows.append(row) } }
        let free = (stock.intrinsicContentSize, label.intrinsicContentSize)
        differ("intrinsic.w", free.0.width, free.1.width)
        differ("intrinsic.h", free.0.height, free.1.height)
        let insets = (stock.alignmentRectInsets, label.alignmentRectInsets)
        differ("insets.left", insets.0.left, insets.1.left)
        differ("insets.right", insets.0.right, insets.1.right)
        differ("insets.top", insets.0.top, insets.1.top)
        differ("insets.bottom", insets.0.bottom, insets.1.bottom)
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            let axis = orientation == .horizontal ? "h" : "v"
            differ("hugging.\(axis)", CGFloat(stock.contentHuggingPriority(for: orientation).rawValue),
                   CGFloat(label.contentHuggingPriority(for: orientation).rawValue))
            differ("resistance.\(axis)", CGFloat(stock.contentCompressionResistancePriority(for: orientation).rawValue),
                   CGFloat(label.contentCompressionResistancePriority(for: orientation).rawValue))
        }
        let fitting = (stock.fittingSize, label.fittingSize)
        differ("fitting.w", fitting.0.width, fitting.1.width)
        differ("fitting.h", fitting.0.height, fitting.1.height)
        root.addSubview(stock)
        root.addSubview(label)
        defer {
            stock.removeFromSuperview()
            label.removeFromSuperview()
        }
        stock.sizeToFit()
        label.sizeToFit()
        differ("sizeToFit.w", stock.frame.width, label.frame.width)
        differ("sizeToFit.h", stock.frame.height, label.frame.height)
        for width in Self.widths {
            let height = max(stock.fittingSize.height, free.0.height, 1)
            stock.frame = NSRect(x: 10, y: 10, width: width, height: height)
            label.frame = NSRect(x: 10, y: 150, width: width, height: height)
            let at = "w\(Int(width))"
            let inks = (Self.ink(cached: stock), Self.ink(cached: label))
            row["\(at).ink.stock"] = "\(inks.0)"
            row["\(at).ink.label"] = "\(inks.1)"
            report.checked += 1
            if !Self.placed(inks.0, inks.1) {
                note("\(name) \(at) ink: stock \(inks.0) label \(inks.1)", into: &report)
                if let imageDirectory, report.imagesWritten < 16 {
                    report.imagesWritten += 1
                    for (view, kind) in [(stock as NSView, "stock"), (label, "label")] {
                        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: imageDirectory.appendingPathComponent("parity-\(report.imagesWritten)-\(kind).png"))
                    }
                }
            }
            // The old ChromeLabel's ink: a copy of the field's cell drawn into the glyph mask.
            let celled = Self.ink(cellOf: stock)
            row["\(at).cell.stock"] = "\(celled)"
            report.checked += 1
            if !Self.placed(celled, inks.1) { note("\(name) \(at) cell ink: old label \(celled) label \(inks.1)", into: &report) }
            label.display()
            let layered = Self.ink(rendered: label)
            row["\(at).layer.label"] = "\(layered)"
            report.checked += 1
            if !Self.same(layered, inks.1) { note("\(name) \(at) layer render: label \(inks.1) label layer \(layered)", into: &report) }
        }
        // Auto Layout, as the app's labels sit: pinned at the top left in a box of each width,
        // the trailing edge at most the box's (the label hugs its text) or equal (it fills).
        for width in Self.widths {
            for fills in [false, true] {
                let at = "auto\(Int(width))\(fills ? "fill" : "hug")"
                let frames = [stock as NSView, label].map { view -> NSRect in
                    let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
                    root.addSubview(box)
                    defer { box.removeFromSuperview() }
                    view.removeFromSuperview()
                    view.translatesAutoresizingMaskIntoConstraints = false
                    box.addSubview(view)
                    NSLayoutConstraint.activate([
                        view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
                        view.topAnchor.constraint(equalTo: box.topAnchor),
                        fills ? view.trailingAnchor.constraint(equalTo: box.trailingAnchor)
                            : view.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
                    ])
                    box.layoutSubtreeIfNeeded()
                    // The second pass a wrapping label's width change asks for.
                    box.layoutSubtreeIfNeeded()
                    let frame = view.frame
                    view.removeFromSuperview()
                    view.translatesAutoresizingMaskIntoConstraints = true
                    root.addSubview(view)
                    return frame
                }
                differ("\(at).w", frames[0].width, frames[1].width)
                differ("\(at).h", frames[0].height, frames[1].height)
                if fills {
                    stock.frame = NSRect(x: 10, y: 10, width: frames[0].width, height: frames[0].height)
                    label.frame = NSRect(x: 10, y: 150, width: frames[1].width, height: frames[1].height)
                    differ("\(at).baseline.first", stock.firstBaselineOffsetFromTop, label.firstBaselineOffsetFromTop)
                    differ("\(at).baseline.last", stock.lastBaselineOffsetFromBottom, label.lastBaselineOffsetFromBottom)
                }
            }
        }
        // A label field is not an accessibility element itself: its cell is (AXStaticText).
        let cell = stock.cell
        let stockAX = cell.map { "\($0.accessibilityRole()?.rawValue ?? "-") \(String(describing: $0.accessibilityValue() ?? "-")) \($0.isAccessibilityElement())" }
            ?? "no cell"
        let labelAX = "\(label.accessibilityRole()?.rawValue ?? "-") \(String(describing: label.accessibilityValue() ?? "-")) \(label.isAccessibilityElement())"
        row["ax.stock"] = stockAX
        row["ax.label"] = labelAX
        report.checked += 1
        if stockAX != labelAX { note("\(name) ax: stock \(stockAX) label \(labelAX)", into: &report) }
        // A label hidden from accessibility stays hidden, as a field does (the field, which
        // stands for its cell in the window's tree, reads the setter back).
        stock.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        report.checked += 1
        let hidden = (stock.isAccessibilityElement(), label.isAccessibilityElement())
        if hidden.0 != hidden.1 { note("\(name) ax hidden: stock element \(hidden.0) label element \(hidden.1)", into: &report) }
        stock.setAccessibilityElement(true)
        label.setAccessibilityElement(true)
        let frames = (cell?.accessibilityFrame() ?? .zero, label.accessibilityFrame())
        let screens = [stock, label].map { $0.window?.convertToScreen($0.convert($0.bounds, to: nil)) ?? .zero }
        differ("ax.frame.dx", frames.0.minX - screens[0].minX, frames.1.minX - screens[1].minX)
        differ("ax.frame.dy", frames.0.minY - screens[0].minY, frames.1.minY - screens[1].minY)
        differ("ax.frame.w", frames.0.width, frames.1.width)
        differ("ax.frame.h", frames.0.height, frames.1.height)
    }

    private func note(_ line: String, into report: inout Report) {
        report.mismatchCount += 1
        if report.mismatches.count < 80 { report.mismatches.append(line) }
    }

    /// The text's ink in a view image: the box of the pixels it covers (pixels, top-left
    /// origin) and the sum of their alpha (0...1 each).
    struct Ink: CustomStringConvertible {
        var box: CGRect
        var amount: Double
        var description: String {
            box.isNull ? "no ink" : "box \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height)) ink \(Int(amount))"
        }
    }

    /// The same pixels covered (within a pixel at each edge): a cached image of a stock field
    /// redraws its text with smoothing on a clear ground (13-22% heavier than on screen, by
    /// font), a ChromeLabel's image is its on-screen glyphs, so only the place is compared.
    private static func placed(_ a: Ink, _ b: Ink) -> Bool {
        if a.amount == 0 || b.amount == 0 { return a.amount == b.amount }
        let edges = [a.box.minX - b.box.minX, a.box.minY - b.box.minY, a.box.maxX - b.box.maxX, a.box.maxY - b.box.maxY]
        return edges.allSatisfy { abs($0) <= 1 }
    }

    private static func same(_ a: Ink, _ b: Ink) -> Bool {
        if a.amount == 0 || b.amount == 0 { return a.amount == b.amount }
        let edges = [a.box.minX - b.box.minX, a.box.minY - b.box.minY, a.box.maxX - b.box.maxX, a.box.maxY - b.box.maxY]
        return edges.allSatisfy { abs($0) <= 1 } && abs(a.amount / b.amount - 1) <= 0.03
    }

    private static func ink(cellOf field: NSTextField) -> Ink {
        guard let cell = field.cell?.copy() as? NSTextFieldCell else { return Ink(box: .null, amount: 0) }
        let size = field.bounds.size
        let image = GlyphMask.image(size: size, scale: field.window?.backingScaleFactor ?? 2, ink: NSColor.black.cgColor) { _, _ in
            cell.drawsBackground = false
            cell.draw(withFrame: NSRect(origin: .zero, size: size), in: field)
        }
        return image.map { ink($0) } ?? Ink(box: .null, amount: 0)
    }

    private static func ink(cached view: NSView) -> Ink {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Ink(box: .null, amount: 0) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return Ink(box: .null, amount: 0) }
        return ink(image)
    }

    private static func ink(rendered view: NSView) -> Ink {
        guard let layer = view.layer else { return Ink(box: .null, amount: 0) }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int((view.bounds.width * scale).rounded(.up)), height = Int((view.bounds.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Ink(box: .null, amount: 0) }
        // Layers are flipped; Core Graphics is not (as TabSnapshotRenderer draws).
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let image = ctx.makeImage() else { return Ink(box: .null, amount: 0) }
        return ink(image)
    }

    private static func ink(_ image: CGImage) -> Ink {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return Ink(box: .null, amount: 0) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var box = CGRect.null, amount = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = bytes[(y * width + x) * 4 + 3]
                guard alpha > 24 else { continue }
                amount += Double(alpha) / 255
                // Row 0 of the context's memory is the top of the image.
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return Ink(box: box, amount: amount)
    }
}
#endif
