public import AppKit

/// Determines whether the main content is placed beside the left sidebar or
/// remains full-width underneath it.
public enum SidebarContentLayoutMode: Equatable, Sendable {
    case sideBySide
    case overlay
}

/// Complete geometry input for ``SidebarContentLayoutView``.
public struct SidebarContentLayoutConfiguration: Equatable, Sendable {
    /// Width of the visible left sidebar.
    public var sidebarWidth: CGFloat
    /// Whether the left sidebar and divider participate in layout.
    public var isSidebarVisible: Bool
    /// Placement relationship between the sidebar and main content.
    public var mode: SidebarContentLayoutMode
    /// Divider hit width extending into the sidebar.
    public var dividerLeadingHitWidth: CGFloat
    /// Divider hit width extending into the main content.
    public var dividerTrailingHitWidth: CGFloat

    public init(
        sidebarWidth: CGFloat,
        isSidebarVisible: Bool,
        mode: SidebarContentLayoutMode,
        dividerLeadingHitWidth: CGFloat,
        dividerTrailingHitWidth: CGFloat
    ) {
        self.sidebarWidth = sidebarWidth
        self.isSidebarVisible = isSidebarVisible
        self.mode = mode
        self.dividerLeadingHitWidth = dividerLeadingHitWidth
        self.dividerTrailingHitWidth = dividerTrailingHitWidth
    }
}

/// AppKit geometry owner for the left sidebar, main content, and draggable divider.
///
/// The hosted views keep their existing rendering implementations. This view
/// owns their horizontal frames and applies each divider update synchronously,
/// so width-sensitive AppKit descendants can remeasure before the mouse event
/// returns.
@MainActor
public final class SidebarContentLayoutView: NSView {
    public let sidebarView: NSView
    public let mainContentView: NSView
    public let dividerView: NSView

    public private(set) var configuration: SidebarContentLayoutConfiguration

    public init(
        sidebarView: NSView,
        mainContentView: NSView,
        dividerView: NSView,
        configuration: SidebarContentLayoutConfiguration
    ) {
        self.sidebarView = sidebarView
        self.mainContentView = mainContentView
        self.dividerView = dividerView
        self.configuration = configuration
        super.init(frame: .zero)

        for child in [mainContentView, sidebarView, dividerView] {
            child.translatesAutoresizingMaskIntoConstraints = true
            child.autoresizingMask = []
            addSubview(child)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies one authoritative layout snapshot.
    ///
    /// Interactive divider callers use the default synchronous path so hosted
    /// table rows see their new viewport width during the same mouse event.
    public func apply(
        configuration: SidebarContentLayoutConfiguration,
        synchronously: Bool = true
    ) {
        guard self.configuration != configuration else {
            if synchronously {
                layoutSubtreeIfNeeded()
                if configuration.isSidebarVisible {
                    sidebarView.layoutSubtreeIfNeeded()
                }
            }
            return
        }

        self.configuration = configuration
        needsLayout = true
        if synchronously {
            layoutSubtreeIfNeeded()
            if configuration.isSidebarVisible {
                sidebarView.layoutSubtreeIfNeeded()
            }
        }
    }

    public override func layout() {
        super.layout()

        let width = min(max(0, configuration.sidebarWidth), max(0, bounds.width))
        let fullBounds = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, bounds.width),
            height: max(0, bounds.height)
        )

        guard configuration.isSidebarVisible else {
            sidebarView.isHidden = true
            dividerView.isHidden = true
            sidebarView.frame = .zero
            dividerView.frame = .zero
            mainContentView.frame = fullBounds
            return
        }

        sidebarView.isHidden = false
        dividerView.isHidden = false
        sidebarView.frame = NSRect(
            x: fullBounds.minX,
            y: fullBounds.minY,
            width: width,
            height: fullBounds.height
        )

        switch configuration.mode {
        case .sideBySide:
            mainContentView.frame = NSRect(
                x: sidebarView.frame.maxX,
                y: fullBounds.minY,
                width: max(0, fullBounds.width - width),
                height: fullBounds.height
            )
        case .overlay:
            mainContentView.frame = fullBounds
        }

        let leadingHitWidth = max(0, configuration.dividerLeadingHitWidth)
        let trailingHitWidth = max(0, configuration.dividerTrailingHitWidth)
        dividerView.frame = NSRect(
            x: sidebarView.frame.maxX - leadingHitWidth,
            y: fullBounds.minY,
            width: leadingHitWidth + trailingHitWidth,
            height: fullBounds.height
        )
    }
}
