internal import CmuxMobileSupport
public import Foundation

/// A transient, non-blocking notice presented through ``ToastCenter``.
///
/// A toast is a value: build one with a semantic factory (``success(_:title:)``,
/// ``failure(_:title:)``, ``warning(_:title:)``, ``info(_:title:)``) and hand it
/// to the center. Styling, motion, haptics, and accessibility all derive from
/// the semantic ``Style`` so call sites never encode visual details.
public struct Toast: Identifiable, Equatable, Sendable {
    /// The semantic voice of a toast; drives tint, icon, haptic, and dwell.
    public enum Style: String, Sendable {
        /// Neutral, ambient information ("Copied", "Agent finished").
        case info
        /// A user- or system-initiated operation completed.
        case success
        /// Something degraded that the user should know about but that did
        /// not fail outright.
        case warning
        /// An operation failed.
        case failure
    }

    /// The screen edge a toast rests against.
    public enum Placement: String, Sendable {
        case top
        case bottom
    }

    /// How long a toast dwells on screen before dismissing itself.
    public enum AutoDismiss: Equatable, Sendable {
        case after(Duration)
        /// Stays until the user dismisses it (tap, swipe) or the center is
        /// told to. Use sparingly: only for states the user must acknowledge.
        case never
    }

    /// A single optional action rendered as a trailing capsule button.
    /// Activating it runs `handler` and dismisses the toast.
    public struct Action: Sendable {
        public let label: String
        public let handler: @MainActor @Sendable () -> Void

        public init(label: String, handler: @escaping @MainActor @Sendable () -> Void) {
            self.label = label
            self.handler = handler
        }
    }

    public private(set) var id: UUID
    public let style: Style
    public let title: String?
    public let message: String
    /// SF Symbol name overriding the style's default icon. `nil` uses the
    /// style default (`info` has none, so plain info toasts read as a quiet
    /// text capsule).
    public let systemImage: String?
    public let placement: Placement
    public let autoDismiss: AutoDismiss
    public let action: Action?
    /// Toasts with equal keys coalesce: presenting one whose key matches the
    /// visible toast refreshes its content in place and re-bumps it instead of
    /// queueing a duplicate behind it. Defaults to style + title + message
    /// (joined on a separator no UI string contains), so identical notices
    /// never stack.
    public let coalescingKey: String

    public init(
        style: Style,
        title: String? = nil,
        message: String,
        systemImage: String? = nil,
        placement: Placement = .top,
        autoDismiss: AutoDismiss? = nil,
        action: Action? = nil,
        coalescingKey: String? = nil
    ) {
        self.id = UUID()
        self.style = style
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.placement = placement
        self.autoDismiss = autoDismiss ?? Self.defaultAutoDismiss(for: style, hasAction: action != nil)
        self.action = action
        self.coalescingKey = coalescingKey
            ?? [style.rawValue, title ?? "\u{0}", message].joined(separator: "\u{1F}")
    }

    public static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
            && lhs.style == rhs.style
            && lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.systemImage == rhs.systemImage
            && lhs.placement == rhs.placement
            && lhs.autoDismiss == rhs.autoDismiss
            && lhs.action?.label == rhs.action?.label
            && lhs.coalescingKey == rhs.coalescingKey
    }

    /// The default dwell for a style: quiet confirmations leave quickly,
    /// problems and actionable toasts stay long enough to read and act on.
    public static func defaultAutoDismiss(for style: Style, hasAction: Bool) -> AutoDismiss {
        if hasAction { return .after(.seconds(6)) }
        switch style {
        case .info, .success:
            return .after(.seconds(3.5))
        case .warning, .failure:
            return .after(.seconds(6))
        }
    }

    /// A copy of this toast that keeps `other`'s identity, used when a
    /// coalescing re-present refreshes the visible toast in place without
    /// re-running the appear transition.
    func adoptingIdentity(of other: Toast) -> Toast {
        var copy = self
        copy.id = other.id
        return copy
    }
}

public extension Toast {
    /// A neutral, ambient notice ("Copied", "Agent finished"). No icon by
    /// default, so plain info toasts read as a quiet text capsule.
    static func info(
        _ message: String,
        title: String? = nil,
        systemImage: String? = nil,
        placement: Placement = .top,
        autoDismiss: AutoDismiss? = nil,
        action: Action? = nil,
        coalescingKey: String? = nil
    ) -> Toast {
        Toast(
            style: .info, title: title, message: message, systemImage: systemImage,
            placement: placement, autoDismiss: autoDismiss, action: action,
            coalescingKey: coalescingKey
        )
    }

    /// Confirms a completed operation with a green check and success haptic.
    static func success(
        _ message: String,
        title: String? = nil,
        systemImage: String? = nil,
        placement: Placement = .top,
        autoDismiss: AutoDismiss? = nil,
        action: Action? = nil,
        coalescingKey: String? = nil
    ) -> Toast {
        Toast(
            style: .success, title: title, message: message, systemImage: systemImage,
            placement: placement, autoDismiss: autoDismiss, action: action,
            coalescingKey: coalescingKey
        )
    }

    /// A degraded-but-working notice with an orange badge and warning haptic.
    static func warning(
        _ message: String,
        title: String? = nil,
        systemImage: String? = nil,
        placement: Placement = .top,
        autoDismiss: AutoDismiss? = nil,
        action: Action? = nil,
        coalescingKey: String? = nil
    ) -> Toast {
        Toast(
            style: .warning, title: title, message: message, systemImage: systemImage,
            placement: placement, autoDismiss: autoDismiss, action: action,
            coalescingKey: coalescingKey
        )
    }

    /// A failed operation: red badge, error haptic, and the longest default
    /// dwell so the reason can be read (pair with a `title` naming the action).
    static func failure(
        _ message: String,
        title: String? = nil,
        systemImage: String? = nil,
        placement: Placement = .top,
        autoDismiss: AutoDismiss? = nil,
        action: Action? = nil,
        coalescingKey: String? = nil
    ) -> Toast {
        Toast(
            style: .failure, title: title, message: message, systemImage: systemImage,
            placement: placement, autoDismiss: autoDismiss, action: action,
            coalescingKey: coalescingKey
        )
    }
}

public extension Toast {
    /// The standard clipboard confirmation: a quiet capsule with a shorter
    /// dwell than a regular notice. Every copy in the app shares one
    /// coalescing key, so rapid copies pulse a single capsule instead of
    /// queueing a parade.
    ///
    /// - Parameter message: Overrides the default "Copied" label (e.g.
    ///   "Path copied") while keeping the shared look and coalescing.
    static func copied(_ message: String? = nil) -> Toast {
        Toast.info(
            message ?? L10n.string("mobile.toast.copied", defaultValue: "Copied"),
            systemImage: "doc.on.doc",
            autoDismiss: .after(.seconds(2.2)),
            coalescingKey: "clipboard"
        )
    }
}

extension Toast {
    /// The icon actually rendered: an explicit override, else the style default.
    var resolvedSystemImage: String? {
        if let systemImage { return systemImage }
        switch style {
        case .info: return nil
        case .success: return "checkmark"
        case .warning: return "exclamationmark"
        case .failure: return "xmark"
        }
    }
}
