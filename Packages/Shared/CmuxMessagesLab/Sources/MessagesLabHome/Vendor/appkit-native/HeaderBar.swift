import AppKit

/// The header as a real macOS 26 titlebar: a unified NSToolbar whose items
/// AppKit renders in Liquid Glass (the avatar, centered; the video button,
/// trailing), and a bottom titlebar accessory with the name pill (a glass
/// NSButton), whose `preferredScrollEdgeEffectStyle` is `.soft`. The
/// transcript scroll view sits under the titlebar with automatic content
/// insets, so AppKit's scroll edge effect (the scroll pocket: a backdrop blur
/// over the scroll view's top inset) covers the transcript under the header.
/// Nothing here draws glass itself.
final class HeaderBar: NSObject, NSToolbarDelegate {
    static let avatarID = NSToolbarItem.Identifier("messages.avatar")
    static let videoID = NSToolbarItem.Identifier("messages.video")
    let toolbar = NSToolbar(identifier: "messages")
    let accessory = NSTitlebarAccessoryViewController()
    let pill = NSButton()
    private let pillContent = PillContentView()
    var title: String = "Instinct" { didSet { applyTitle() } }
    var onVideo: () -> Void = {}
    var onContact: () -> Void = {}

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        toolbar.centeredItemIdentifiers = [Self.avatarID]

        pill.bezelStyle = .glass
        pill.borderShape = .capsule
        pill.controlSize = .large
        pill.imagePosition = .imageTrailing
        pill.image = HeaderBar.pillImageMode ? nil : HeaderBar.chevronImage()
        pill.imageHugsTitle = true
        pill.font = .systemFont(ofSize: 13, weight: .bold)
        pill.target = self
        pill.action = #selector(contactClicked)
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            // Messages' pill is centered 58 pt from the window top (measured
            // on the recording: whole device pixels 88-144); the accessory
            // below the 52 pt toolbar centers at 70.
            pill.centerYAnchor.constraint(equalTo: holder.centerYAnchor, constant: HeaderBar.pillLift),
            holder.heightAnchor.constraint(equalToConstant: HeaderBar.accessoryHeight),
            // Messages' pill width for "Instinct" is 77.75 pt; it follows the
            // title's width.
            pill.widthAnchor.constraint(equalToConstant: HeaderBar.pillWidth(title)),
            // Messages' pill is 28 pt tall (y 43.5-71.5 on the recording); without a title
            // the large glass button would shrink to 22 pt.
            pill.heightAnchor.constraint(equalToConstant: 28),
        ])
        accessory.view = holder
        accessory.layoutAttribute = .bottom
        if #available(macOS 26.1, *) { accessory.preferredScrollEdgeEffectStyle = .soft }
        applyTitle()
    }

    /// The accessory's height: the toolbar plus the accessory span the
    /// shared header's 80 pt when the toolbar is 52 pt.
    static let accessoryHeight: CGFloat = 28
    static func flag(_ name: String, _ fallback: CGFloat) -> CGFloat {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]).map { CGFloat($0) } : nil } ?? fallback
    }
    /// The pill's title and chevron sit 1 pt right of AppKit's centering in
    /// Messages (ink x 262-360.5 pt against 261-359.5).
    /// Messages' chevron in the active window: 9 pt tall, about 3.5 pt
    /// wide, starting 6 pt after the title's ink (measured on the recording,
    /// x 366-369.5, y 54-62.5 pt), lighter than the glass behind it.
    static let chevronPoint = flag("--chev-pt", 11)
    static let chevronWhite = flag("--chev-white", 0.58)
    static let chevronPad = flag("--chev-pad", 0)
    static let chevronWeight = flag("--chev-weight", 4)
    static let chevronCompact = flag("--chev-compact", 1) != 0
    static func chevronImage() -> NSImage? {
        guard let sym = NSImage(systemSymbolName: chevronCompact ? "chevron.compact.right" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: chevronPoint, weight: [NSFont.Weight.light, .regular, .medium, .semibold, .bold][Int(chevronWeight)])
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: chevronWhite, alpha: 1)]))) else { return nil }
        if chevronPad == 0 { return sym }
        let size = NSSize(width: sym.size.width + chevronPad, height: sym.size.height)
        return NSImage(size: size, flipped: false) { _ in
            sym.draw(in: NSRect(x: chevronPad, y: 0, width: sym.size.width, height: sym.size.height))
            return true
        }
    }
    /// The avatar disc's top, from the window top (measured: 8 pt).
    static let avatarTop = flag("--avatar-top", 8)
    static let pillLift: CGFloat = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "--pill-lift").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]).map { CGFloat($0) } : nil } ?? -12
    }()

    /// Messages' pill width: 77.75 pt for "Instinct", plus the title's extra width.
    static let pillImageMode = flag("--pill-image", 1) != 0
    static let pillTitleX = flag("--pill-title-x", 11.5)
    static let pillTitleY = flag("--pill-title-y", 3)
    static let chevronGap = flag("--chev-gap", 3)
    static let chevronDrop = flag("--chev-dy", 0.5)
    /// Draws the pill's title and chevron at the measured places (rect: the pill's bounds,
    /// flipped).
    static func drawPillContent(_ title: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        // Messages' title is opaque (255 levels in dark mode; labelColor is 85 % white).
        let ink = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black }
        let s = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        s.draw(at: NSPoint(x: rect.minX + pillTitleX, y: rect.minY + pillTitleY))
        if let chev = chevronImage() {
            let x = rect.minX + pillTitleX + s.size().width + chevronGap
            chev.draw(in: NSRect(x: x, y: rect.minY + (rect.height - chev.size.height) / 2 + chevronDrop, width: chev.size.width, height: chev.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
    static func pillWidth(_ title: String) -> CGFloat {
        let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
        return TextDraw.width(title, font: bold) + 77.75 - TextDraw.width("Instinct", font: bold)
    }
    private var widthConstraint: NSLayoutConstraint? { pill.constraints.first { $0.firstAttribute == .width } }

    private func applyTitle() {
        widthConstraint?.constant = HeaderBar.pillWidth(title)
        if HeaderBar.pillImageMode {
            // Messages' title starts 12.5 pt inside the pill and its chevron
            // 6 pt after the title's ink; the glass button (a hosted SwiftUI
            // button) insets its title 11.5 pt and ignores attachments, kerning
            // and indents, and draws its image at reduced strength (title 238
            // levels, Messages 255). The button keeps no title or image; a
            // content view on it draws the title and chevron at the measured
            // places at full strength.
            pill.title = ""
            pill.image = nil
            pillContent.title = self.title
            if pillContent.superview == nil {
                pillContent.translatesAutoresizingMaskIntoConstraints = false
                pill.addSubview(pillContent)
                NSLayoutConstraint.activate([
                    pillContent.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
                    pillContent.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
                    pillContent.topAnchor.constraint(equalTo: pill.topAnchor),
                    pillContent.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
                ])
            }
        } else {
            pill.title = self.title
        }
        pill.setAccessibilityLabel(String(format: NativeStrings.contactFormat, title))
        pill.toolTip = pill.accessibilityLabel()
    }

    func install(in window: NSWindow) {
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func contactClicked() { onContact() }
    @objc private func videoClicked() { onVideo() }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.avatarID, .flexibleSpace, Self.videoID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.avatarID:
            let item = NSToolbarItem(itemIdentifier: id)
            // Messages' avatar disc spans y 8-48 pt in the window (measured on
            // the recording). A toolbar item's viewer is 38 pt tall at y 6-44
            // and clips, so the item holds an empty 40 x 38 view and the image
            // goes into the titlebar view, 8 pt from the window top and
            // centered on the item (AvatarHolder).
            let holder = AvatarHolder(image: HeaderBar.avatarImage(title))
            holder.setAccessibilityElement(true)
            holder.setAccessibilityRole(.image)
            holder.setAccessibilityLabel(title)
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.widthAnchor.constraint(equalToConstant: 40).isActive = true
            holder.heightAnchor.constraint(equalToConstant: 38).isActive = true
            item.view = holder
            item.isBordered = false
            item.label = title
            return item
        case Self.videoID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "video", accessibilityDescription: NativeStrings.video)
            item.label = NativeStrings.video
            item.toolTip = NativeStrings.video
            item.isBordered = true
            item.target = self
            item.action = #selector(videoClicked)
            return item
        default:
            return nil
        }
    }

    /// The contact's avatar: the shared header drawing's avatar (the
    /// monogram measured on the recording), drawn at the destination's scale.
    static func avatarImage(_ name: String) -> NSImage {
        NSImage(size: NSSize(width: 40, height: 40), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // The disc only: the shared overlay also paints the header's
            // bands, which show under the disc's lower corners.
            ctx.addEllipse(in: r.insetBy(dx: -0.5, dy: -0.5))
            ctx.clip()
            ctx.translateBy(x: -294, y: -8)
            // drawOverlay draws the whole header overlay; the clip keeps the
            // avatar's 40 x 40 pt.
            HeaderView.drawOverlay(ctx, CGRect(x: 0, y: 0, width: Fixture.windowWidth, height: Fixture.headerHeight))
            ctx.restoreGState()
            return true
        }
    }
}

/// The avatar's toolbar item view. It is empty: the toolbar puts item
/// views in a glass container that cuts them off at y 44, and Messages' disc
/// spans y 8-48 pt. The image goes into the titlebar view instead, centered
/// on the window (as the centered item is) and HeaderBar.avatarTop from the
/// window top, kept there by its autoresizing mask. (The toolbar rejects
/// constraints that pierce its item viewers.)
private final class AvatarHolder: NSView {
    /// A plain layer view (an NSImageView in the titlebar draws dimmed while the window is
    /// not key; Messages keeps the avatar at full strength).
    let imageView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    init(image: NSImage) {
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 38))
        imageView.wantsLayer = true
        imageView.layer?.contents = image
        imageView.layer?.contentsGravity = .resize
        imageView.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { imageView.removeFromSuperview() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageView.removeFromSuperview()
        guard window != nil else { return }
        var v = superview
        while let s = v, !String(describing: type(of: s)).hasSuffix("TitlebarView") { v = s.superview }
        guard let bar = v else {
            imageView.frame = NSRect(x: 0, y: (bounds.height - 40) / 2, width: 40, height: 40)
            addSubview(imageView)
            return
        }
        let b = bar.bounds
        let y = bar.isFlipped ? HeaderBar.avatarTop : b.height - HeaderBar.avatarTop - 40
        imageView.frame = NSRect(x: (b.width - 40) / 2, y: y, width: 40, height: 40)
        imageView.autoresizingMask = [.minXMargin, .maxXMargin, bar.isFlipped ? .maxYMargin : .minYMargin]
        bar.addSubview(imageView)
    }
}


/// The contact pill's title and chevron, drawn over the glass button (clicks pass to it).
private final class PillContentView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { HeaderBar.drawPillContent(title, in: bounds) }
}
