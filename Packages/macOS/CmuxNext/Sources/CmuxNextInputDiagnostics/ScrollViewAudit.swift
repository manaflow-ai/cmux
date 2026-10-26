public import AppKit
internal import ObjectiveC

/// `debug.input` section `scroll_views`: every live `NSScrollView` and whether AppKit can scroll it
/// on its own thread (responsive scrolling), for p03-rendering-110's owner (p04-input.md task 048,
/// MQ-responsive-scroll). Chrome keeps scrolling off the main thread with its compositor
/// (cc/input/input_handler.cc); AppKit's matching path is responsive scrolling, which a scroll view
/// leaves when its class, clip view or document view overrides `scrollWheel(_:)`, or its document
/// view draws and is not compatible (AppKit 10.9 release notes, "Responsive Scrolling").
///
/// Each read walks the windows once, on the main actor; nothing observes views between reads.
public nonisolated struct DebugInputScrollViews: Sendable, Equatable, Codable {
    /// One scroll view. Class names and window numbers only: no titles, no user text.
    public nonisolated struct Row: Sendable, Equatable, Codable {
        /// The window's `windowNumber`.
        public var window: Int
        /// The window's class (`NSWindow`, `NSPanel`, an app subclass).
        public var windowClass: String
        /// Whether the window is on screen.
        public var windowVisible: Bool
        /// The scroll view's class, generic arguments left out.
        public var scrollViewClass: String
        /// The clip view's class.
        public var clipViewClass: String
        /// The document view's class; nil when the scroll view has none.
        public var documentViewClass: String?
        /// `isCompatibleWithResponsiveScrolling` of the scroll view's class.
        public var scrollViewCompatible: Bool
        /// `isCompatibleWithResponsiveScrolling` of the document view's class; nil without one.
        public var documentViewCompatible: Bool?
        /// Whether the document view's class overrides `draw(_:)`; nil without one.
        public var documentViewOverridesDraw: Bool?
        /// The views whose class overrides `scrollWheel(_:)`, from `scroll_view`, `clip_view` and
        /// `document_view`, in that order.
        public var scrollWheelOverrides: [String]
        /// Whether the scroll view is SwiftUI's or sits inside a SwiftUI hosting view.
        public var swiftUIHosted: Bool
        /// AppKit's rule over the fields above: the scroll view's class is compatible, no view
        /// overrides `scrollWheel(_:)`, and the document view is compatible or does not draw.
        public var responsive: Bool

        public init(window: Int, windowClass: String, windowVisible: Bool, scrollViewClass: String, clipViewClass: String,
                    documentViewClass: String?, scrollViewCompatible: Bool, documentViewCompatible: Bool?,
                    documentViewOverridesDraw: Bool?, scrollWheelOverrides: [String], swiftUIHosted: Bool) {
            self.window = window
            self.windowClass = windowClass
            self.windowVisible = windowVisible
            self.scrollViewClass = scrollViewClass
            self.clipViewClass = clipViewClass
            self.documentViewClass = documentViewClass
            self.scrollViewCompatible = scrollViewCompatible
            self.documentViewCompatible = documentViewCompatible
            self.documentViewOverridesDraw = documentViewOverridesDraw
            self.scrollWheelOverrides = scrollWheelOverrides
            self.swiftUIHosted = swiftUIHosted
            responsive = scrollViewCompatible && scrollWheelOverrides.isEmpty
                && ((documentViewCompatible ?? true) || documentViewOverridesDraw != true)
        }

        private enum CodingKeys: String, CodingKey {
            case window
            case windowClass = "window_class"
            case windowVisible = "window_visible"
            case scrollViewClass = "scroll_view_class"
            case clipViewClass = "clip_view_class"
            case documentViewClass = "document_view_class"
            case scrollViewCompatible = "scroll_view_compatible"
            case documentViewCompatible = "document_view_compatible"
            case documentViewOverridesDraw = "document_view_overrides_draw"
            case scrollWheelOverrides = "scroll_wheel_overrides"
            case swiftUIHosted = "swiftui_hosted"
            case responsive
        }
    }

    /// One row per scroll view, windows in the order given, views in depth-first subview order.
    public var rows: [Row]
    /// The rows whose `responsive` is false: MQ-responsive-scroll's count.
    public var notResponsive: Int

    public init(rows: [Row]) {
        self.rows = rows
        notResponsive = rows.count(where: { !$0.responsive })
    }

    private enum CodingKeys: String, CodingKey {
        case rows
        case notResponsive = "not_responsive"
    }
}

extension DebugInputScrollViews {
    /// One window to walk: what its rows say about it, and the view to start from.
    struct WindowRoot {
        let number: Int
        let className: String
        let visible: Bool
        let root: NSView
    }

    /// The scroll views of `windows`, from each window's frame view (title bar accessories too).
    @MainActor
    public init(auditing windows: [NSWindow]) {
        self.init(auditing: windows.compactMap { window in
            (window.contentView?.superview ?? window.contentView).map { root in
                WindowRoot(number: window.windowNumber, className: Self.className(type(of: window)),
                           visible: window.isVisible, root: root)
            }
        })
    }

    @MainActor
    init(auditing roots: [WindowRoot]) {
        var rows: [Row] = []
        for window in roots {
            var stack: [NSView] = [window.root]
            while let view = stack.popLast() {
                if let scrollView = view as? NSScrollView { rows.append(Self.row(scrollView, in: window)) }
                stack.append(contentsOf: view.subviews.reversed())
            }
        }
        self.init(rows: rows)
    }

    @MainActor
    private static func row(_ scrollView: NSScrollView, in window: WindowRoot) -> Row {
        let scrollClass: AnyClass = type(of: scrollView)
        let clipClass: AnyClass = type(of: scrollView.contentView)
        let documentClass: AnyClass? = scrollView.documentView.map { type(of: $0) }
        let wheel = #selector(NSResponder.scrollWheel(with:))
        var wheelOverrides: [String] = []
        if overrides(scrollClass, wheel, base: NSScrollView.self) { wheelOverrides.append("scroll_view") }
        if overrides(clipClass, wheel, base: NSClipView.self) { wheelOverrides.append("clip_view") }
        if let documentClass, overrides(documentClass, wheel, base: NSView.self) { wheelOverrides.append("document_view") }
        return Row(window: window.number, windowClass: window.className, windowVisible: window.visible,
                   scrollViewClass: className(scrollClass), clipViewClass: className(clipClass),
                   documentViewClass: documentClass.map(className),
                   scrollViewCompatible: type(of: scrollView).isCompatibleWithResponsiveScrolling,
                   documentViewCompatible: scrollView.documentView.map { type(of: $0).isCompatibleWithResponsiveScrolling },
                   documentViewOverridesDraw: documentClass.map { overrides($0, #selector(NSView.draw(_:)), base: NSView.self) },
                   scrollWheelOverrides: wheelOverrides, swiftUIHosted: isSwiftUIHosted(scrollView))
    }

    /// Whether `cls` or a class between it and `base` implements `selector` itself. Without an
    /// override the runtime resolves both lookups to the same method.
    static func overrides(_ cls: AnyClass, _ selector: Selector, base: AnyClass) -> Bool {
        class_getInstanceMethod(cls, selector) != class_getInstanceMethod(base, selector)
    }

    /// The class's Swift name without generic arguments (`SwiftUI.NSHostingView`), so a row does not
    /// carry a SwiftUI view tree's type.
    static func className(_ cls: AnyClass) -> String {
        let name = String(reflecting: cls)
        return name.firstIndex(of: "<").map { String(name[..<$0]) } ?? name
    }

    @MainActor
    private static func isSwiftUIHosted(_ scrollView: NSScrollView) -> Bool {
        var view: NSView? = scrollView
        while let current = view {
            if String(reflecting: type(of: current)).hasPrefix("SwiftUI.") { return true }
            view = current.superview
        }
        return false
    }
}

/// `debug.input` section `scroll_views` (task 048): one walk of the App's windows per read, nothing
/// between reads. The App passes the walk with its own classed main-thread hop, so this package
/// neither reaches for `NSApp` nor posts unclassed main work.
///
/// ```swift
/// ScrollViewAuditSource { [mainWork] in
///     await mainWork.apply(.automation, owner: "debug.input.scroll_views") { DebugInputScrollViews(auditing: NSApp.windows) }
/// }
/// ```
public nonisolated struct ScrollViewAuditSource: DebugInputSource {
    private let audit: @Sendable () async -> DebugInputScrollViews

    /// - Parameter audit: Walks the live windows on the main thread (``DebugInputScrollViews/init(auditing:)``).
    public init(audit: @escaping @Sendable () async -> DebugInputScrollViews) {
        self.audit = audit
    }

    public var section: DebugInputSection { .scrollViews }

    public func read() async -> DebugInputScrollViews {
        await audit()
    }

    /// The audit keeps no counters: nothing to start over.
    public func reset() async {}
}
