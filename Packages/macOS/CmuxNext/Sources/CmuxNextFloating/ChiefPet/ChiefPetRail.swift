import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The rail under the pet, as the references draw it: a glass capsule of round tool buttons
/// (compose; the notices' expand once there are notices). Under Reduce Transparency it is the
/// solid overlay surface. Its background is part of the pet's drag area.
final class ChiefPetRail: NSView {
    static let height: CGFloat = 40
    static let slot: CGFloat = 44

    private let surface: NSView
    private let stack = NSStackView()

    override init(frame: NSRect) {
        surface = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? Glass.makeOverlayPanel(cornerRadius: Self.height / 2) as NSView
            : Glass.makePanel(style: .regular, cornerRadius: Self.height / 2, interactive: true)
        super.init(frame: frame)
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The rail's width for its tool buttons.
    var width: CGFloat { Self.slot * CGFloat(max(1, stack.arrangedSubviews.count)) }

    @discardableResult
    func addTool(_ icon: IconName, label: String, turned degrees: CGFloat = 0, action: @escaping () -> Void) -> ChiefPetTool {
        let tool = ChiefPetTool(icon: icon, label: label, turned: degrees, action: action)
        stack.addArrangedSubview(tool)
        return tool
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        stack.frame = bounds
    }
}

/// One round tool on the rail: an icon in the theme's primary ink, no bezel.
final class ChiefPetTool: NSButton {
    private let run: () -> Void
    /// The icon's turn, counterclockwise: the chevron is the disclosure mark pointing up, as the dock draws it.
    private var degrees: CGFloat
    private var icon: IconName

    init(icon: IconName, label: String, turned degrees: CGFloat = 0, action: @escaping () -> Void) {
        run = action
        self.degrees = degrees
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: ChiefPetRail.slot, height: ChiefPetRail.height))
        isBordered = false
        imagePosition = .imageOnly
        setIcon(icon)
        setAccessibilityLabel(label)
        toolTip = label
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Turns the icon (the chevron points down while the notices are unfolded).
    func turn(to degrees: CGFloat) {
        guard degrees != self.degrees else { return }
        self.degrees = degrees
        setIcon(icon)
    }

    func setIcon(_ icon: IconName) {
        self.icon = icon
        image = Self.turned(NSImage.icon(icon, size: 18), by: degrees)
        recolor()
    }

    /// `image` turned about its center, still a template so it takes the tint.
    static func turned(_ image: NSImage, by degrees: CGFloat) -> NSImage {
        guard degrees != 0, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let width = CGFloat(source.width), height = CGFloat(source.height)
        context.translateBy(x: width / 2, y: height / 2)
        context.rotate(by: degrees * .pi / 180)
        context.translateBy(x: -width / 2, y: -height / 2)
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rotated = context.makeImage() else { return image }
        let turned = NSImage(cgImage: rotated, size: image.size)
        turned.isTemplate = image.isTemplate
        return turned
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolor()
    }

    private func recolor() {
        contentTintColor = performWithTheme { Palette.textPrimary }
    }

    @objc private func fire() { run() }
}
