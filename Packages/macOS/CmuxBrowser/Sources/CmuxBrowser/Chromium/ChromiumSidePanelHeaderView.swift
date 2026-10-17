public import AppKit

/// A control of Chromium's side panel header, as `cmux_side_panel_press`
/// names it.
public enum ChromiumSidePanelControl: String, Sendable, CaseIterable {
    case pin
    case openInNewTab = "open_in_new_tab"
    case moreInfo = "more_info"
    case close
}

/// What cmux's side panel header shows: Chromium's panel title and icon and
/// the controls Chromium's own header shows.
public struct ChromiumSidePanelHeaderContent: Equatable, Sendable {
    public var title: String
    /// PNG data of the panel's icon, when it has one.
    public var icon: Data?
    public var isPinned: Bool
    /// The controls to show, in Chromium's order.
    public var controls: [ChromiumSidePanelControl]

    public init(title: String, icon: Data?, isPinned: Bool, controls: [ChromiumSidePanelControl]) {
        self.title = title
        self.icon = icon
        self.isPinned = isPinned
        self.controls = controls
    }
}

/// cmux's header over a Chromium page's side panel (`chrome.sidePanel`):
/// icon, title and the controls Chromium's header shows (pin to the
/// toolbar, open in a new tab, more info, close) in system colors. Chromium's
/// own buttons are out of the focus order and the accessibility tree while
/// cmux draws this header, so these are real buttons for the keyboard and
/// VoiceOver; each runs Chromium's button through `onPress`.
///
/// Reference: cmux Next `CmuxNextBrowser/UI/SidePanelHeaderView.swift`.
public final class ChromiumSidePanelHeaderView: NSView {
    public var onPress: (@MainActor (ChromiumSidePanelControl) -> Void)?
    public private(set) var content: ChromiumSidePanelHeaderContent?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var buttons: [ChromiumSidePanelControl: NSButton] = [:]

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("browser.sidePanel.header")
        icon.imageScaling = .scaleProportionallyDown
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.spacing = 2
        for control in ChromiumSidePanelControl.allCases {
            let button = NSButton(title: "", target: self, action: #selector(pressButton(_:)))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.identifier = NSUserInterfaceItemIdentifier("browser.sidePanel.\(control.rawValue)")
            button.tag = ChromiumSidePanelControl.allCases.firstIndex(of: control) ?? 0
            buttons[control] = button
            stack.addArrangedSubview(button)
        }
        for view in [icon, title, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: stack.leadingAnchor, constant: -8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func apply(_ content: ChromiumSidePanelHeaderContent) {
        self.content = content
        title.stringValue = content.title
        setAccessibilityLabel(content.title)
        icon.image = content.icon.flatMap(NSImage.init(data:))
        icon.isHidden = icon.image == nil
        for (control, button) in buttons {
            button.isHidden = !content.controls.contains(control)
            let label = Self.label(for: control, pinned: content.isPinned)
            button.image = NSImage(systemSymbolName: Self.symbol(for: control, pinned: content.isPinned),
                                   accessibilityDescription: label)
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
    }

    /// The control's name for the tooltip and VoiceOver.
    public static func label(for control: ChromiumSidePanelControl, pinned: Bool) -> String {
        switch control {
        case .pin:
            pinned
                ? String(localized: "browser.chromium.sidePanel.unpin", defaultValue: "Unpin from Toolbar", bundle: .module)
                : String(localized: "browser.chromium.sidePanel.pin", defaultValue: "Pin to Toolbar", bundle: .module)
        case .openInNewTab:
            String(localized: "browser.chromium.sidePanel.openInNewTab", defaultValue: "Open in New Tab", bundle: .module)
        case .moreInfo:
            String(localized: "browser.chromium.sidePanel.moreInfo", defaultValue: "More Options", bundle: .module)
        case .close:
            String(localized: "browser.chromium.sidePanel.close", defaultValue: "Close Side Panel", bundle: .module)
        }
    }

    static func symbol(for control: ChromiumSidePanelControl, pinned: Bool) -> String {
        switch control {
        case .pin: pinned ? "pin.fill" : "pin"
        case .openInNewTab: "arrow.up.forward.square"
        case .moreInfo: "ellipsis"
        case .close: "xmark"
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        title.textColor = .labelColor
    }

    @objc private func pressButton(_ sender: NSButton) {
        let controls = ChromiumSidePanelControl.allCases
        guard controls.indices.contains(sender.tag) else { return }
        onPress?(controls[sender.tag])
    }
}
