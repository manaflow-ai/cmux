import AppKit
import CmuxFoundation
import CmuxSwiftRender
import CoreImage
import QuartzCore

/// Native renderer for the interpreted sidebar render tree.
@MainActor
final class RenderNodeView: NSView, SidebarTapTargetProviding {
    let node: RenderNode
    let dispatch: SidebarActionDispatch
    let contentInsets: CustomSidebarContentInsets
    let sidebarTapAction: ButtonAction?

    private let renderedView: NSView
    private var padding = NSEdgeInsets()
    private var clipShape: SidebarClipShape?

    init(
        node: RenderNode,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero
    ) {
        self.node = node
        self.dispatch = dispatch
        self.contentInsets = contentInsets
        sidebarTapAction = node.kind == .button ? nil : node.action
        renderedView = Self.makeContent(
            node: node, dispatch: dispatch, contentInsets: contentInsets
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        installRenderedView()
        applyModifiers()
        setAccessibilityElement(node.kind.isAccessibilityElement)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        let fitting = renderedView.fittingSize
        return NSSize(
            width: ceil(fitting.width + padding.left + padding.right),
            height: ceil(fitting.height + padding.top + padding.bottom)
        )
    }

    override func layout() {
        super.layout()
        guard let clipShape else { return }
        let radius: CGFloat
        switch clipShape {
        case .rectangle: radius = 0
        case let .rounded(value): radius = value
        case .capsule: radius = min(bounds.width, bounds.height) / 2
        case .circle, .ellipse: radius = min(bounds.width, bounds.height) / 2
        }
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard sidebarTapAction != nil, bounds.contains(point) else { return super.hitTest(point) }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        guard let sidebarTapAction else {
            super.mouseUp(with: event)
            return
        }
        dispatch.run(sidebarTapAction)
    }

    private func installRenderedView() {
        renderedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renderedView)
        NSLayoutConstraint.activate([
            renderedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderedView.topAnchor.constraint(equalTo: topAnchor),
            renderedView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private static func makeContent(
        node: RenderNode,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) -> NSView {
        let children = {
            node.children.map {
                RenderNodeView(node: $0, dispatch: dispatch, contentInsets: contentInsets)
            }
        }

        switch node.kind {
        case .vstack, .lazyVStack, .group, .list:
            return stack(orientation: .vertical, spacing: node.spacing, views: children())
        case .hstack, .lazyHStack, .gridRow:
            return stack(orientation: .horizontal, spacing: node.spacing, views: children())
        case .zstack:
            return SidebarOverlayView(views: children())
        case .section:
            var views: [NSView] = []
            if let header = node.text, !header.isEmpty {
                let label = textLabel(header)
                label.font = GlobalFontMagnification.systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .secondaryLabelColor
                views.append(label)
            }
            views.append(contentsOf: children())
            return stack(orientation: .vertical, spacing: node.spacing ?? 4, views: views)
        case .hscroll:
            let document = stack(orientation: .horizontal, spacing: node.spacing, views: children())
            return SidebarScrollContainer(documentView: document, axis: .horizontal)
        case .grid:
            return grid(node: node, dispatch: dispatch, contentInsets: contentInsets)
        case .lazyVGrid:
            return adaptiveGrid(node: node, columns: 2, dispatch: dispatch, contentInsets: contentInsets)
        case .lazyHGrid:
            return adaptiveGrid(
                node: node, columns: max(1, Int(ceil(Double(node.children.count) / 2))), dispatch: dispatch,
                contentInsets: contentInsets
            )
        case .viewThatFits:
            return children().first ?? NSView()
        case .hsplit:
            return ResizableHSplit(
                columns: node.children, dispatch: dispatch, contentInsets: contentInsets
            )
        case .reorderable:
            return ReorderableList(
                rows: node.children, spec: node.reorder, dispatch: dispatch, contentInsets: contentInsets
            )
        case .text:
            return textLabel(node.text ?? "")
        case .label:
            let image = imageView(systemName: node.systemName ?? "circle")
            return stack(
                orientation: .horizontal, spacing: 6, views: [image, textLabel(node.text ?? "")]
            )
        case .image:
            return imageView(systemName: node.systemName ?? "questionmark.square.dashed")
        case .button:
            if node.children.isEmpty {
                return SidebarActionButton(title: node.text ?? "", action: node.action, dispatch: dispatch)
            }
            let label = stack(orientation: .vertical, spacing: 0, views: children())
            return SidebarActionControl(contentView: label, action: node.action, dispatch: dispatch)
        case .spacer:
            return SidebarSpacerView(minimumLength: CGFloat(node.spacing ?? 0))
        case .divider:
            let box = NSBox()
            box.boxType = .separator
            return box
        case .rectangle:
            return SidebarShapeView(shape: .rectangle)
        case .roundedRectangle, .unevenRoundedRectangle:
            return SidebarShapeView(shape: .rounded(CGFloat(node.cornerRadius ?? 6)))
        case .capsule:
            return SidebarShapeView(shape: .capsule)
        case .circle:
            return SidebarShapeView(shape: .circle)
        case .ellipse:
            return SidebarShapeView(shape: .ellipse)
        case .progressView:
            return progressView(value: node.value, label: node.text)
        case .gauge:
            return gaugeView(value: node.value, label: node.text)
        case .menu:
            return SidebarMenuButton(node: node, dispatch: dispatch)
        case .linearGradient:
            return SidebarGradientView(node: node, type: .axial)
        case .radialGradient:
            return SidebarGradientView(node: node, type: .radial)
        case .angularGradient:
            return SidebarGradientView(node: node, type: .conic)
        }
    }

    private static func stack(
        orientation: NSUserInterfaceLayoutOrientation,
        spacing: Double?,
        views: [NSView]
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.spacing = CGFloat(spacing ?? 8)
        stack.alignment = orientation == .vertical ? .leading : .centerY
        stack.distribution = .gravityAreas
        stack.translatesAutoresizingMaskIntoConstraints = false
        if orientation == .vertical {
            for view in views {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    private static func textLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: 13)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func imageView(systemName: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: GlobalFontMagnification.scaled(13),
                    weight: .regular
                )
            )
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = .labelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private static func progressView(value: Double?, label: String?) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = value == nil ? .spinning : .bar
        progress.isIndeterminate = value == nil
        if let value {
            progress.minValue = 0
            progress.maxValue = 1
            progress.doubleValue = min(1, max(0, value))
        } else {
            progress.startAnimation(nil)
        }
        guard let label, !label.isEmpty else { return progress }
        return stack(orientation: .vertical, spacing: 4, views: [textLabel(label), progress])
    }

    private static func gaugeView(value: Double?, label: String?) -> NSView {
        guard let value else { return NSView() }
        let gauge = NSLevelIndicator()
        gauge.levelIndicatorStyle = .continuousCapacity
        gauge.minValue = 0
        gauge.maxValue = 1
        gauge.doubleValue = min(1, max(0, value))
        guard let label, !label.isEmpty else { return gauge }
        return stack(orientation: .vertical, spacing: 4, views: [textLabel(label), gauge])
    }

    private static func grid(
        node: RenderNode,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) -> NSGridView {
        let rows = node.children.map { row -> [NSView] in
            let cells = row.kind == .gridRow ? row.children : [row]
            return cells.map {
                RenderNodeView(node: $0, dispatch: dispatch, contentInsets: contentInsets)
            }
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = CGFloat(node.spacing ?? 8)
        grid.columnSpacing = CGFloat(node.spacing ?? 8)
        grid.xPlacement = .leading
        return grid
    }

    private static func adaptiveGrid(
        node: RenderNode,
        columns: Int,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) -> NSGridView {
        var rows: [[NSView]] = []
        var row: [NSView] = []
        for child in node.children {
            row.append(RenderNodeView(node: child, dispatch: dispatch, contentInsets: contentInsets))
            if row.count == columns {
                rows.append(row)
                row = []
            }
        }
        if !row.isEmpty {
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = CGFloat(node.spacing ?? 8)
        grid.columnSpacing = CGFloat(node.spacing ?? 8)
        grid.xPlacement = .fill
        return grid
    }

    private func applyModifiers() {
        let modifiers = node.modifiers
        applyTextModifiers(modifiers)
        var transform = CGAffineTransform.identity
        var filters: [CIFilter] = []

        for modifier in modifiers {
            let token = clean(modifier.firstValue)
            switch modifier.name {
            case "foregroundColor", "foregroundStyle", "fill", "tint":
                if let color = dslColor(token) {
                    applyForeground(color)
                }
            case "padding":
                let value = token.flatMap(Double.init).map { CGFloat($0) } ?? 8
                padding = NSEdgeInsets(top: value, left: value, bottom: value, right: value)
                updateRenderedViewInsets()
            case "background":
                if let color = dslColor(token) {
                    layer?.backgroundColor = resolvedCGColor(color)
                }
                installModifierChildren(modifier, positioned: .below)
            case "overlay":
                if let color = dslColor(token) {
                    layer?.borderColor = resolvedCGColor(color)
                    layer?.borderWidth = 1
                }
                installModifierChildren(modifier, positioned: .above)
            case "mask", "clipped":
                layer?.masksToBounds = true
            case "safeAreaInset":
                installModifierChildren(modifier, positioned: .above)
            case "cornerRadius":
                if let value = token.flatMap(Double.init) {
                    clipShape = .rounded(CGFloat(value))
                }
            case "opacity":
                if let value = token.flatMap(Double.init) {
                    alphaValue = value
                }
            case "lineLimit":
                if let value = token.flatMap(Int.init) {
                    descendants(of: NSTextField.self).forEach { $0.maximumNumberOfLines = value }
                }
            case "frame":
                applyFrame(modifier)
            case "shadow":
                wantsLayer = true
                layer?.shadowColor = resolvedCGColor(dslColor(clean(modifier.value("color"))) ?? .black)
                layer?.shadowOpacity = 0.33
                layer?.shadowRadius = CGFloat(
                    modDouble(modifier, "radius") ?? token.flatMap(Double.init) ?? 4
                )
                layer?.shadowOffset = CGSize(
                    width: CGFloat(modDouble(modifier, "x") ?? 0),
                    height: CGFloat(-(modDouble(modifier, "y") ?? 0))
                )
            case "border":
                layer?.borderColor = resolvedCGColor(dslColor(token) ?? .separatorColor)
                layer?.borderWidth = CGFloat(modDouble(modifier, "width") ?? 1)
            case "blur":
                if let filter = CIFilter(name: "CIGaussianBlur") {
                    filter.setValue(
                        modDouble(modifier, "radius") ?? token.flatMap(Double.init) ?? 0,
                        forKey: kCIInputRadiusKey
                    )
                    filters.append(filter)
                }
            case "offset":
                transform = transform.translatedBy(
                    x: CGFloat(modDouble(modifier, "x") ?? 0),
                    y: CGFloat(modDouble(modifier, "y") ?? 0)
                )
            case "scaleEffect":
                if let scale = token.flatMap(Double.init) {
                    transform = transform.scaledBy(x: scale, y: scale)
                }
            case "rotationEffect":
                transform = transform.rotated(by: CGFloat((angleDegrees(token) ?? 0) * .pi / 180))
            case "zIndex":
                layer?.zPosition = CGFloat(token.flatMap(Double.init) ?? 0)
            case "brightness":
                appendColorFilter(
                    "CIColorControls", key: kCIInputBrightnessKey, value: token.flatMap(Double.init) ?? 0,
                    to: &filters
                )
            case "contrast":
                appendColorFilter(
                    "CIColorControls", key: kCIInputContrastKey, value: token.flatMap(Double.init) ?? 1,
                    to: &filters
                )
            case "saturation":
                appendColorFilter(
                    "CIColorControls", key: kCIInputSaturationKey, value: token.flatMap(Double.init) ?? 1,
                    to: &filters
                )
            case "grayscale":
                appendColorFilter(
                    "CIColorControls", key: kCIInputSaturationKey,
                    value: 1 - (token.flatMap(Double.init) ?? 0), to: &filters
                )
            case "clipShape":
                clipShape = resolvedClipShape(token)
            case "imageScale":
                applyImageScale(dslImageScale(token))
            case "contextMenu":
                menu = makeMenu(nodes: modifier.children)
            case "help":
                toolTip = token
            case "keyboardShortcut":
                if let key = dslKeyEquivalent(token) {
                    for descendant in descendants(of: NSButton.self) {
                        descendant.keyEquivalent = key
                        descendant.keyEquivalentModifierMask = dslEventModifiers(modifier.value("modifiers"))
                    }
                }
            case "disabled":
                if token == "true" {
                    descendants(of: NSControl.self).forEach { $0.isEnabled = false }
                }
            case "redacted":
                alphaValue = 0.55
            case "unredacted":
                alphaValue = 1
            case "accessibilityLabel":
                setAccessibilityLabel(token ?? "")
            case "accessibilityHint":
                setAccessibilityHelp(token ?? "")
            case "accessibilityValue":
                setAccessibilityValue(token ?? "")
            case "accessibilityHidden":
                setAccessibilityElement(token == "false")
            case "scrollIndicators":
                let visible = token != "hidden" && token != "never"
                for descendant in descendants(of: NSScrollView.self) {
                    descendant.hasVerticalScroller = visible
                    descendant.hasHorizontalScroller = visible
                }
            case "aspectRatio":
                if let ratio = token.flatMap(Double.init), ratio > 0 {
                    widthAnchor.constraint(equalTo: heightAnchor, multiplier: ratio).isActive = true
                }
            case "scaledToFit":
                descendants(of: NSImageView.self).forEach { $0.imageScaling = .scaleProportionallyUpOrDown }
            case "scaledToFill":
                descendants(of: NSImageView.self).forEach { $0.imageScaling = .scaleAxesIndependently }
            case "fixedSize":
                setContentHuggingPriority(.required, for: .horizontal)
                setContentHuggingPriority(.required, for: .vertical)
            case "layoutPriority":
                let priority = Float(min(999, max(1, 250 + (token.flatMap(Double.init) ?? 0) * 100)))
                setContentHuggingPriority(NSLayoutConstraint.Priority(priority), for: .horizontal)
                setContentCompressionResistancePriority(
                    NSLayoutConstraint.Priority(priority), for: .horizontal
                )
            default:
                continue
            }
        }

        layer?.setAffineTransform(transform)
        if !filters.isEmpty {
            layer?.filters = filters
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func applyTextModifiers(_ modifiers: [RenderModifier]) {
        var spec = resolveFontSpec(
            modifiers.first(where: { $0.name == "font" }).flatMap { clean($0.firstValue) }
        )
        var weight = modifiers.first(where: { $0.name == "fontWeight" }).flatMap {
            dslFontWeight(clean($0.firstValue))
        }
        if modifiers.contains(where: { $0.name == "bold" }) {
            weight = .bold
        }
        let design = modifiers.first(where: { $0.name == "fontDesign" }).flatMap {
            dslFontDesign(clean($0.firstValue))
        }
        if modifiers.contains(where: { $0.name == "monospaced" }) {
            spec = DSLFontSpec(
                baseSize: spec?.baseSize ?? 13, weight: weight ?? spec?.weight, design: .monospaced
            )
        }
        if let design {
            spec = DSLFontSpec(
                baseSize: spec?.baseSize ?? 13, weight: weight ?? spec?.weight, design: design
            )
        }
        if let weight {
            spec = DSLFontSpec(
                baseSize: spec?.baseSize ?? 13, weight: weight, design: spec?.design ?? .default
            )
        }

        let font = dslFont(spec)
        let alignment = modifiers.first(where: { $0.name == "multilineTextAlignment" })
            .map { dslTextAlignment(clean($0.firstValue)) }
        let textCase = modifiers.first(where: { $0.name == "textCase" })
            .flatMap { dslTextCase(clean($0.firstValue)) }
        let truncation = modifiers.first(where: { $0.name == "truncationMode" })
            .map { dslTruncationMode(clean($0.firstValue)) }

        for label in descendants(of: NSTextField.self) {
            if let font {
                label.font = font
            }
            if let alignment {
                label.alignment = alignment
            }
            if let truncation {
                label.lineBreakMode = truncation
            }
            if let textCase {
                label.stringValue =
                    textCase == .uppercase
                        ? label.stringValue.uppercased()
                        : label.stringValue.lowercased()
            }
            applyTextDecorations(modifiers, to: label)
        }
        for button in descendants(of: NSButton.self) {
            if let font {
                button.font = font
            }
        }
    }

    private func applyTextDecorations(_ modifiers: [RenderModifier], to label: NSTextField) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: label.font ?? GlobalFontMagnification.systemFont(ofSize: 13),
            .foregroundColor: label.textColor ?? NSColor.labelColor,
        ]
        if modifiers.contains(where: { $0.name == "underline" }) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if modifiers.contains(where: { $0.name == "strikethrough" }) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        label.attributedStringValue = NSAttributedString(
            string: label.stringValue, attributes: attributes
        )
    }

    private func applyForeground(_ color: NSColor) {
        descendants(of: NSTextField.self).forEach { $0.textColor = color }
        descendants(of: NSImageView.self).forEach { $0.contentTintColor = color }
        descendants(of: NSButton.self).forEach { $0.contentTintColor = color }
        descendants(of: SidebarShapeView.self).forEach { $0.fillColor = color }
    }

    private func updateRenderedViewInsets() {
        guard
            let leading = constraints.first(where: {
                $0.firstItem === renderedView && $0.firstAttribute == .leading
            }),
            let trailing = constraints.first(where: {
                $0.firstItem === renderedView && $0.firstAttribute == .trailing
            }),
            let top = constraints.first(where: {
                $0.firstItem === renderedView && $0.firstAttribute == .top
            }),
            let bottom = constraints.first(where: {
                $0.firstItem === renderedView && $0.firstAttribute == .bottom
            })
        else { return }
        leading.constant = padding.left
        trailing.constant = -padding.right
        top.constant = padding.top
        bottom.constant = -padding.bottom
    }

    private func installModifierChildren(
        _ modifier: RenderModifier, positioned: NSWindow.OrderingMode
    ) {
        guard !modifier.children.isEmpty else { return }
        let views = modifier.children.map {
            RenderNodeView(node: $0, dispatch: dispatch, contentInsets: contentInsets)
        }
        let overlay = SidebarOverlayView(views: views)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay, positioned: positioned, relativeTo: renderedView)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applyFrame(_ modifier: RenderModifier) {
        func dimension(_ label: String) -> CGFloat? {
            guard let raw = modifier.value(label), raw != ".infinity", raw != "infinity" else {
                return nil
            }
            return Double(raw).map { CGFloat($0) }
        }
        if let width = dimension("width") {
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        if let height = dimension("height") {
            heightAnchor.constraint(equalToConstant: height).isActive = true
        }
        if let minWidth = dimension("minWidth") {
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth).isActive = true
        }
        if let maxWidth = dimension("maxWidth") {
            widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        }
        if let minHeight = dimension("minHeight") {
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        }
        if let maxHeight = dimension("maxHeight") {
            heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight).isActive = true
        }
        if modifier.value("maxWidth")?.contains("infinity") == true {
            setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        if modifier.value("maxHeight")?.contains("infinity") == true {
            setContentHuggingPriority(.defaultLow, for: .vertical)
        }
    }

    private func applyImageScale(_ scale: CGFloat) {
        for imageView in descendants(of: NSImageView.self) {
            guard let image = imageView.image else { continue }
            imageView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: GlobalFontMagnification.scaled(13 * scale),
                    weight: .regular
                )
            )
        }
    }

    private func makeMenu(nodes: [RenderNode]) -> NSMenu {
        let menu = NSMenu()
        for node in nodes {
            let item = SidebarMenuItem(
                title: node.text ?? "", actionValue: node.action, dispatch: dispatch
            )
            menu.addItem(item)
        }
        return menu
    }

    private func descendants<T: NSView>(of _: T.Type) -> [T] {
        var result: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T {
                result.append(match)
            }
            view.subviews.forEach(walk)
        }
        walk(self)
        return result
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
        }
        return resolved
    }

    private func appendColorFilter(
        _ name: String, key: String, value: Double, to filters: inout [CIFilter]
    ) {
        guard let filter = CIFilter(name: name) else { return }
        filter.setValue(value, forKey: key)
        filters.append(filter)
    }

    private func resolvedClipShape(_ token: String?) -> SidebarClipShape {
        switch token?.lowercased() {
        case let value? where value.hasPrefix("circle"): return .circle
        case let value? where value.hasPrefix("capsule"): return .capsule
        case let value? where value.hasPrefix("ellipse"): return .ellipse
        case let value? where value.hasPrefix("rectangle"): return .rectangle
        default: return .rounded(8)
        }
    }

    private func resolveFontSpec(_ token: String?) -> DSLFontSpec? {
        guard let token else { return nil }
        guard token.hasPrefix("system") else { return dslFontSpec(named: token, size: nil) }
        let design: DSLFontDesign = token.contains("monospaced") ? .monospaced : .default
        let weight = resolveFontWeight(in: token)
        if let range = token.range(of: "size:") {
            let digits = token[range.upperBound...].drop(while: { $0 == " " })
                .prefix(while: { $0.isNumber || $0 == "." })
            if let value = Double(digits) {
                return dslFontSpec(named: nil, size: value, weight: weight, design: design)
            }
        }
        for name in [
            "largeTitle", "title3", "title2", "title", "headline", "subheadline", "body", "callout",
            "footnote", "caption2", "caption",
        ] where token.contains(name) {
            return dslFontSpec(named: name, size: nil, weight: weight, design: design)
        }
        return dslFontSpec(named: nil, size: 13, weight: weight, design: design)
    }

    private func resolveFontWeight(in token: String) -> NSFont.Weight? {
        guard let range = token.range(of: "weight:") else { return nil }
        let raw = token[range.upperBound...].drop(while: { $0 == " " || $0 == "." })
            .prefix(while: { $0.isLetter })
        return dslFontWeight(String(raw))
    }

    private func modDouble(_ modifier: RenderModifier, _ label: String) -> Double? {
        modifier.value(label).map { clean($0) ?? $0 }.flatMap(Double.init)
    }

    private func angleDegrees(_ token: String?) -> Double? {
        guard let token else { return nil }
        if let open = token.firstIndex(of: "("), let close = token.lastIndex(of: ")") {
            let inner = String(token[token.index(after: open) ..< close])
            guard let value = Double(inner.trimmingCharacters(in: .whitespaces)) else { return nil }
            return token.contains("radians") ? value * 180 / .pi : value
        }
        return Double(token)
    }

    private func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix(".") {
            return String(raw.dropFirst())
        }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}

private enum SidebarClipShape {
    case rectangle
    case rounded(CGFloat)
    case capsule
    case circle
    case ellipse
}

@MainActor
private final class SidebarOverlayView: NSView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        subviews.reduce(.zero) { result, view in
            let fitting = view.fittingSize
            return NSSize(
                width: max(result.width, fitting.width), height: max(result.height, fitting.height)
            )
        }
    }
}

@MainActor
private final class SidebarSpacerView: NSView {
    private let minimumLength: CGFloat

    init(minimumLength: CGFloat) {
        self.minimumLength = minimumLength
        super.init(frame: .zero)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: minimumLength, height: minimumLength)
    }
}

@MainActor
private final class SidebarActionButton: NSButton, SidebarTapTargetProviding {
    let sidebarTapAction: ButtonAction?
    private let dispatch: SidebarActionDispatch

    init(title: String, action: ButtonAction?, dispatch: SidebarActionDispatch) {
        sidebarTapAction = action
        self.dispatch = dispatch
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(runAction)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction() {
        if let sidebarTapAction {
            dispatch.run(sidebarTapAction)
        }
    }
}

@MainActor
private final class SidebarActionControl: NSControl, SidebarTapTargetProviding {
    let sidebarTapAction: ButtonAction?
    private let dispatch: SidebarActionDispatch

    init(contentView: NSView, action: ButtonAction?, dispatch: SidebarActionDispatch) {
        sidebarTapAction = action
        self.dispatch = dispatch
        super.init(frame: .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        subviews.first?.fittingSize ?? .zero
    }

    override func mouseUp(with _: NSEvent) {
        if let sidebarTapAction {
            dispatch.run(sidebarTapAction)
        }
    }
}

@MainActor
private final class SidebarMenuButton: NSPopUpButton {
    private let dispatch: SidebarActionDispatch
    private var actions: [Int: ButtonAction] = [:]

    init(node: RenderNode, dispatch: SidebarActionDispatch) {
        self.dispatch = dispatch
        super.init(frame: .zero, pullsDown: true)
        title = node.text ?? ""
        menu = NSMenu()
        for (index, child) in node.children.enumerated() {
            let item = NSMenuItem(
                title: child.text ?? "", action: #selector(runItem(_:)), keyEquivalent: ""
            )
            item.tag = index
            item.target = self
            menu?.addItem(item)
            if let action = child.action {
                actions[index] = action
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runItem(_ sender: NSMenuItem) {
        if let action = actions[sender.tag] {
            dispatch.run(action)
        }
    }
}

@MainActor
private final class SidebarMenuItem: NSMenuItem {
    private let actionValue: ButtonAction?
    private let dispatch: SidebarActionDispatch

    init(title: String, actionValue: ButtonAction?, dispatch: SidebarActionDispatch) {
        self.actionValue = actionValue
        self.dispatch = dispatch
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        action = #selector(runAction)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction() {
        if let actionValue {
            dispatch.run(actionValue)
        }
    }
}

@MainActor
private final class SidebarShapeView: NSView {
    let shape: SidebarClipShape
    var fillColor = NSColor.secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    var strokeColor: NSColor?
    var strokeWidth: CGFloat = 0

    init(shape: SidebarClipShape) {
        self.shape = shape
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override func draw(_: NSRect) {
        let path: NSBezierPath
        switch shape {
        case .rectangle:
            path = NSBezierPath(rect: bounds)
        case let .rounded(radius):
            path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        case .capsule:
            path = NSBezierPath(
                roundedRect: bounds, xRadius: min(bounds.width, bounds.height) / 2,
                yRadius: min(bounds.width, bounds.height) / 2
            )
        case .circle:
            let side = min(bounds.width, bounds.height)
            path = NSBezierPath(
                ovalIn: CGRect(
                    x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side
                )
            )
        case .ellipse:
            path = NSBezierPath(ovalIn: bounds)
        }
        fillColor.setFill()
        path.fill()
        if let strokeColor, strokeWidth > 0 {
            strokeColor.setStroke()
            path.lineWidth = strokeWidth
            path.stroke()
        }
    }
}

@MainActor
private final class SidebarGradientView: NSView {
    private let gradientLayer = CAGradientLayer()

    init(node: RenderNode, type: CAGradientLayerType) {
        super.init(frame: .zero)
        wantsLayer = true
        gradientLayer.type = type
        let colors = node.colors.compactMap(dslColor)
        gradientLayer.colors = (colors.count >= 2 ? colors : colors + [.clear, .clear]).map(\.cgColor)
        gradientLayer.startPoint = dslUnitPoint(node.points.first, default: CGPoint(x: 0.5, y: 0))
        gradientLayer.endPoint = dslUnitPoint(
            node.points.count > 1 ? node.points[1] : nil, default: CGPoint(x: 0.5, y: 1)
        )
        layer?.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 60, height: 60)
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }
}

@MainActor
final class SidebarScrollContainer: NSScrollView {
    enum Axis { case horizontal, vertical }

    init(documentView: NSView, axis: Axis) {
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = axis == .horizontal
        hasVerticalScroller = axis == .vertical
        autohidesScrollers = true
        let document = SidebarFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(documentView)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        self.documentView = document
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: document.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        if axis == .horizontal {
            document.heightAnchor.constraint(equalTo: contentView.heightAnchor).isActive = true
        } else {
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
class SidebarFlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private extension RenderNode.Kind {
    var isAccessibilityElement: Bool {
        switch self {
        case .text, .label, .image, .button, .progressView, .gauge, .menu:
            return true
        default:
            return false
        }
    }
}
