public import AppKit

extension WindowPictureStore {
    /// A pane on screen at the quit: its content area and what the picture shows there.
    public struct Pane {
        /// What a pane's content area shows in the window's picture.
        public enum Content {
            /// A picture of `view` (a terminal's surface, an agent page's area), drawn at the view's frame.
            case picture(CGImage, of: NSView)
            /// A picture drawn at `frame`, in points from the content area's top-left corner (a browser page at its
            /// page frame within the toolbar and page).
            case placed(CGImage, at: CGRect)
            /// `view`'s frame filled with the theme background: what it shows must never reach the disk (a terminal
            /// holding Secure Input, a page withheld or not captured).
            case fill(NSView)
            /// AppKit drew it already (a cmux page, the empty state).
            case drawn
        }

        /// The tab the pane shows.
        public let key: String
        public let area: NSView
        public let content: Content

        public init(key: String, area: NSView, content: Content) {
            (self.key, self.area, self.content) = (key, area, content)
        }
    }

    /// What the quit knows of a window apart from its views.
    public nonisolated struct Window: Sendable {
        /// The window's stable id and the room it shows.
        public let id: String, profile: String
        public let incognito: Bool
        /// The theme's fingerprint (``WindowPictureMeta/fingerprint(_:)``) and its opaque background (the fills').
        public let theme: String, background: Color
        public let build: String
        public let layout: WindowPictureMeta.Layout
        /// The stable id of the display that shows it.
        public let screen: String?

        public init(id: String, profile: String, incognito: Bool, theme: String, background: Color, build: String,
                    layout: WindowPictureMeta.Layout, screen: String?) {
            (self.id, self.profile, self.incognito, self.theme, self.background) = (id, profile, incognito, theme, background)
            (self.build, self.layout, self.screen) = (build, layout, screen)
        }
    }

    /// `window`'s shot now, or nil for one that may leave no picture (``Eligibility``) or draws none: `root` drawn
    /// once without `backdrop` (``capture(_:hiding:)``), each pane on screen at its content area with its
    /// ``Pane/Content``, the fills over them, and the meta. Only geometry reads and the one draw run here; composing
    /// and the encode run in ``save(_:)``.
    ///
    /// - Parameters:
    ///   - sidebar: The sidebar while it shows (its region); nil while hidden.
    public static func shot(of window: NSWindow, root: NSView, backdrop: NSView?, sidebar: NSView?, panes: [Pane],
                            facts: Window) -> Shot? {
        let eligibility = Eligibility(window: window, incognito: facts.incognito)
        guard eligibility.allowsPicture, let base = capture(root, hiding: backdrop) else { return nil }
        var layers: [Layer] = [], fills: [CGRect] = [], regions: [WindowPictureMeta.Region] = []
        if let sidebar, VisiblePaneRefs.Window.isOnScreen(sidebar) {
            regions.append(.init(kind: .sidebar, id: "sidebar", frame: frame(of: sidebar, in: root)))
        }
        for pane in panes where VisiblePaneRefs.Window.isOnScreen(pane.area) {
            let area = frame(of: pane.area, in: root)
            regions.append(.init(kind: .pane, id: pane.key, frame: area))
            switch pane.content {
            case .picture(let image, let view): layers.append(Layer(image: image, frame: frame(of: view, in: root)))
            case .placed(let image, let rect): layers.append(Layer(image: image, frame: rect.offsetBy(dx: area.minX, dy: area.minY)))
            case .fill(let view): fills.append(frame(of: view, in: root))
            case .drawn: break
            }
        }
        let meta = WindowPictureMeta(
            window: facts.id, profile: facts.profile, frame: window.frame, screen: facts.screen, scale: Double(window.backingScaleFactor),
            appearance: window.effectiveAppearance.name.rawValue, theme: facts.theme,
            sidebarWidth: sidebar.map { Double($0.frame.width) } ?? 0, build: facts.build, layout: facts.layout,
            regions: regions.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) })
        return Shot(eligibility: eligibility, base: base, size: root.bounds.size, layers: layers, fills: fills,
                    background: facts.background, meta: meta)
    }

    /// `view`'s bounds in `root`, in points from `root`'s top-left corner.
    static func frame(of view: NSView, in root: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: root)
        return root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
