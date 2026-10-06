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
        // Messages' chevron: small and dim (measured grey 0.42).
        pill.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.42, alpha: 1)])))
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
        ])
        accessory.view = holder
        accessory.layoutAttribute = .bottom
        if #available(macOS 26.1, *) { accessory.preferredScrollEdgeEffectStyle = .soft }
        applyTitle()
    }

    /// The accessory's height: the toolbar plus the accessory span the
    /// shared header's 80 pt when the toolbar is 52 pt.
    static let accessoryHeight: CGFloat = 28
    static let pillLift: CGFloat = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "--pill-lift").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]).map { CGFloat($0) } : nil } ?? -12
    }()

    /// Messages' pill width: 77.75 pt for "Instinct", plus the title's extra width.
    static func pillWidth(_ title: String) -> CGFloat {
        let bold = NSFont.systemFont(ofSize: 13, weight: .bold)
        return TextDraw.width(title, font: bold) + 77.75 - TextDraw.width("Instinct", font: bold)
    }
    private var widthConstraint: NSLayoutConstraint? { pill.constraints.first { $0.firstAttribute == .width } }

    private func applyTitle() {
        widthConstraint?.constant = HeaderBar.pillWidth(title)
        pill.title = title
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
            let v = NSImageView(image: HeaderBar.avatarImage(title))
            v.imageScaling = .scaleProportionallyUpOrDown
            v.setAccessibilityLabel(title)
            v.widthAnchor.constraint(equalToConstant: 40).isActive = true
            v.heightAnchor.constraint(equalToConstant: 40).isActive = true
            item.view = v
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
            ctx.clip(to: r)
            ctx.translateBy(x: -294, y: -8)
            // drawOverlay draws the whole header overlay; the clip keeps the
            // avatar's 40 x 40 pt.
            HeaderView.drawOverlay(ctx, CGRect(x: 0, y: 0, width: Fixture.windowWidth, height: Fixture.headerHeight))
            ctx.restoreGState()
            return true
        }
    }
}
