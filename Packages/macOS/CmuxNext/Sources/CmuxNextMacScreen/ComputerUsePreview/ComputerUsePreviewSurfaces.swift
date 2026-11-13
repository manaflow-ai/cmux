// SPDX-License-Identifier: GPL-3.0-or-later
public import AppKit
public import AVFoundation
import CmuxNextDesign

/// The chip a hidden preview leaves at the top right of its surface; a click shows it again.
@MainActor
public final class ComputerUsePreviewChip: NSButton {
    private let onShow: () -> Void

    public init(onShow: @escaping () -> Void) {
        self.onShow = onShow
        super.init(frame: .zero)
        title = ComputerUsePreviewText.chip
        image = NSImage(systemSymbolName: "pip", accessibilityDescription: nil)
        imagePosition = .imageLeading
        font = NSFont.systemFont(ofSize: TypeScale.caption, weight: TypeScale.emphasis)
        bezelStyle = .inline
        controlSize = .small
        refusesFirstResponder = true
        toolTip = ComputerUsePreviewText.chipHelp
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }

    @objc private func clicked() { onShow() }
}

/// The expanded view: the live picture large over a dimmed surface. A click anywhere or Escape
/// (the controller's key monitor) closes it; it never takes the keyboard.
@MainActor
public final class ComputerUsePreviewExpanded: NSView {
    public var onClose: () -> Void = {}
    public var aspect: CGFloat = 16.0 / 10.0 { didSet { needsLayout = true } }
    private let scrim = NSView()
    private let picture = ComputerUsePreviewPictureView(cornerRadius: 8)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        addSubview(scrim)
        picture.shadow = NSShadow()
        addSubview(picture)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(ComputerUsePreviewText.expandedLabel)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public func attach(video layer: AVSampleBufferDisplayLayer?) { picture.attach(video: layer) }

    /// Shows a still in place of the video (nil: the video shows).
    public func show(still image: CGImage?) { picture.show(still: image) }

    /// A still is shown (tests).
    var showsStill: Bool { picture.showsStill }

    public override func layout() {
        super.layout()
        scrim.frame = bounds
        let size = ComputerUsePreviewLayout(aspect: aspect).expandedSize(in: bounds.size)
        picture.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    public override func mouseDown(with event: NSEvent) { onClose() }
}

/// The preview's strings.
@MainActor
public struct ComputerUsePreviewText {
    public static var thumbnailLabel: String {
        String(localized: "computerUse.preview.label", defaultValue: "Computer Use preview", table: "CmuxRemote", bundle: .module)
    }
    public static var expandedLabel: String {
        String(localized: "computerUse.preview.expandedLabel", defaultValue: "Computer Use preview, expanded",
               table: "CmuxRemote", bundle: .module)
    }
    public static var expand: String {
        String(localized: "computerUse.preview.expand", defaultValue: "Expand", table: "CmuxRemote", bundle: .module)
    }
    public static var showWindow: String {
        String(localized: "computerUse.preview.showWindow", defaultValue: "Show Window", table: "CmuxRemote", bundle: .module)
    }
    public static var hide: String {
        String(localized: "computerUse.preview.hide", defaultValue: "Hide", table: "CmuxRemote", bundle: .module)
    }
    public static var hideHere: String {
        String(localized: "computerUse.preview.hideHere", defaultValue: "Hide for This Chat", table: "CmuxRemote", bundle: .module)
    }
    /// On an agent's terminal, where there is no chat.
    public static var hideHereAgent: String {
        String(localized: "computerUse.preview.hideHereAgent", defaultValue: "Hide for This Agent", table: "CmuxRemote", bundle: .module)
    }
    public static var hideEverywhere: String {
        String(localized: "computerUse.preview.hideEverywhere", defaultValue: "Hide for All Active Chats", table: "CmuxRemote",
               bundle: .module)
    }
    public static var chip: String {
        String(localized: "computerUse.preview.chip", defaultValue: "Live Preview", table: "CmuxRemote", bundle: .module)
    }
    public static var chipHelp: String {
        String(localized: "computerUse.preview.chipHelp", defaultValue: "Show the live preview of the window the agent uses",
               table: "CmuxRemote", bundle: .module)
    }

    public init() {}
}
