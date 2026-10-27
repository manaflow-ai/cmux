public import CoreGraphics
import CryptoKit
public import Foundation

/// What a saved window picture (``WindowPictureStore``) shows and of which window, written beside it at quit
/// (p08-startup 3C). A launch shows the picture only when every field matches the window it opens
/// (``mismatches(_:)``); the layout is compared per region, so a sidebar whose rows changed takes today's path
/// while the content area still shows its picture.
///
/// Chrome keeps the same facts beside a capture for the same reason: Android's paint preview stores the capture's
/// URL, size and version and drops it on any mismatch
/// (components/paint_preview/browser/paint_preview_base_service.cc, `PaintPreviewProto`'s `metadata`).
public nonisolated struct WindowPictureMeta: Codable, Sendable, Equatable {
    /// The file format this build writes and reads; a meta of another format never matches.
    public static let currentFormat = 1

    public var format: Int
    /// The window's stable id (`WindowState.id`).
    public var window: String
    /// The room the window showed (`WindowState.profileID`): the picture's folder.
    public var profile: String
    /// The window's frame in AppKit screen coordinates.
    public var frame: CGRect
    /// The stable id of the display that showed the window; nil when it had none.
    public var screen: String?
    /// The window's backing scale.
    public var scale: Double
    /// The window's effective appearance (`NSAppearance.Name`, `NSAppearanceNameDarkAqua`).
    public var appearance: String
    /// The theme's fingerprint (``fingerprint(_:)`` of the theme's colors), the same in every launch with the same
    /// theme. The theme store's in-memory generation starts over each launch, so it cannot be compared.
    public var theme: String
    /// The sidebar's width on screen in points; 0 while hidden.
    public var sidebarWidth: Double
    /// The app's version and build (``build(of:)``).
    public var build: String
    public var layout: Layout
    /// Where the picture's regions sit, in points from its top-left corner: the launch replaces each with live
    /// content on its own (a pane at its first frame).
    public var regions: [Region]
    /// The browser profiles whose pages the picture shows, sorted: Clear Browsing Data and a profile's delete remove
    /// the pictures showing that profile (`LaunchPictureStore`). Nil: not known (a meta written before it was
    /// recorded), so any profile's clear removes the picture. Never compared at launch.
    public var browserProfiles: [UUID]?

    public init(window: String, profile: String, frame: CGRect, screen: String?, scale: Double, appearance: String,
                theme: String, sidebarWidth: Double, build: String, layout: Layout, regions: [Region],
                browserProfiles: [UUID]? = nil) {
        format = Self.currentFormat
        (self.window, self.profile, self.frame, self.screen, self.scale) = (window, profile, frame, screen, scale)
        (self.appearance, self.theme, self.sidebarWidth, self.build) = (appearance, theme, sidebarWidth, build)
        (self.layout, self.regions, self.browserProfiles) = (layout, regions, browserProfiles)
    }

    /// Whether the picture may show a page of browser profile `profile` (``browserProfiles``; not known: yes).
    public func mayShow(browserProfile profile: UUID) -> Bool {
        browserProfiles?.contains(profile) ?? true
    }

    /// Whether the picture shows tab `key` in one of its panes.
    public func shows(tab key: String) -> Bool {
        regions.contains { $0.kind == .pane && $0.id == key }
    }

    /// A field a launch compares with the window it opens.
    public enum Field: String, Sendable, CaseIterable {
        case format, window, profile, frame, screen, scale, appearance, theme, sidebarWidth, build
        /// The sidebar's rows (``Layout/sidebar``).
        case sidebarLayout
        /// The content area's panes (``Layout/content``).
        case contentLayout
    }

    /// The fields where `other` (the window a launch opens) differs from this picture's: empty, the picture shows
    /// that window. Frames and widths match within half a point (a restored frame is rounded to the backing grid).
    public func mismatches(_ other: Self) -> Set<Field> {
        var fields: Set<Field> = []
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }
        if format != other.format { fields.insert(.format) }
        if window != other.window { fields.insert(.window) }
        if profile != other.profile { fields.insert(.profile) }
        if !(close(frame.minX, other.frame.minX) && close(frame.minY, other.frame.minY)
             && close(frame.width, other.frame.width) && close(frame.height, other.frame.height)) { fields.insert(.frame) }
        if screen != other.screen { fields.insert(.screen) }
        if scale != other.scale { fields.insert(.scale) }
        if appearance != other.appearance { fields.insert(.appearance) }
        if theme != other.theme { fields.insert(.theme) }
        if !close(sidebarWidth, other.sidebarWidth) { fields.insert(.sidebarWidth) }
        if build != other.build { fields.insert(.build) }
        if layout.sidebar != other.layout.sidebar { fields.insert(.sidebarLayout) }
        if layout.content != other.layout.content { fields.insert(.contentLayout) }
        return fields
    }

    /// `bundle`'s version and build (`CFBundleShortVersionString (CFBundleVersion)`): a picture another build drew
    /// may show chrome this one draws differently.
    public static func build(of bundle: Bundle) -> String {
        let info = bundle.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "0") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }

    /// A stable digest of `parts` (SHA-256, hex): the same parts give the same digest in every process, unlike
    /// `Hasher`, which is seeded per process.
    public static func fingerprint(_ parts: [String]) -> String {
        var digest = Digest()
        for part in parts { digest.add(part) }
        return digest.hex()
    }

    /// The picture's layout, one digest per region a launch compares on its own.
    public struct Layout: Codable, Sendable, Equatable {
        /// The sidebar's rows: the window's workspaces in sidebar order and the shown one.
        public var sidebar: String
        /// The content area: what the window shows and the pane tree of each of its screens.
        public var content: String

        /// - Parameters:
        ///   - workspaces: The window's workspace IDs in sidebar order.
        ///   - shown: What the window shows: its workspace's ID, or a top page's route; nil for the empty state.
        ///   - screens: The shown workspace's screens in order.
        public init(workspaces: [String], shown: String?, screens: [Screen]) {
            var sidebar = Digest()
            sidebar.add("sidebar")
            sidebar.add(shown ?? "-")
            for workspace in workspaces { sidebar.add(workspace) }
            self.sidebar = sidebar.hex()
            var content = Digest()
            content.add("content")
            content.add(shown ?? "-")
            for screen in screens { screen.add(to: &content) }
            self.content = content.hex()
        }
    }

    /// One screen of the shown workspace.
    public struct Screen: Sendable, Hashable {
        public var id: String
        public var tree: PaneTree
        /// The zoomed pane, if any: it fills the screen.
        public var zoomed: String?

        public init(id: String, tree: PaneTree, zoomed: String?) {
            (self.id, self.tree, self.zoomed) = (id, tree, zoomed)
        }

        func add(to digest: inout Digest) {
            digest.add("screen")
            digest.add(id)
            digest.add(zoomed ?? "-")
            tree.add(to: &digest)
        }
    }

    /// A screen's split tree, as the daemon's layout names it (the app maps its `LayoutNode`).
    public indirect enum PaneTree: Sendable, Hashable {
        case leaf(String)
        /// `vertical`: stacked (`a` on top); else side by side. `ratio` is `a`'s share, 0...1.
        case split(vertical: Bool, ratio: Double, a: PaneTree, b: PaneTree)
        case stack(panes: [String], expanded: String)
        /// A node this build does not know: it never matches a known one.
        case unknown

        func add(to digest: inout Digest) {
            switch self {
            case .leaf(let pane):
                digest.add("leaf")
                digest.add(pane)
            case .split(let vertical, let ratio, let a, let b):
                digest.add(vertical ? "down" : "right")
                // Thousandths: a ratio the daemon rounds differently is the same layout on screen.
                digest.add(String(Int((min(max(ratio, 0), 1) * 1000).rounded())))
                a.add(to: &digest)
                b.add(to: &digest)
            case .stack(let panes, let expanded):
                digest.add("stack")
                digest.add(expanded)
                digest.add(String(panes.count))
                for pane in panes { digest.add(pane) }
            case .unknown:
                digest.add("unknown")
            }
        }
    }

    /// A part of the picture a launch replaces on its own.
    public struct Region: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case sidebar
            /// A pane's content area; ``Region/id`` is the tab it showed.
            case pane
        }

        public var kind: Kind
        public var id: String
        /// In points from the picture's top-left corner.
        public var frame: CGRect

        public init(kind: Kind, id: String, frame: CGRect) {
            (self.kind, self.id, self.frame) = (kind, id, frame)
        }
    }

    /// SHA-256 over length-prefixed parts (`<byte count>:<part>`), so no two lists of parts give the same bytes.
    struct Digest {
        private var hash = SHA256()

        mutating func add(_ part: String) {
            hash.update(data: Data("\(part.utf8.count):\(part)".utf8))
        }

        func hex() -> String {
            let digits = Array("0123456789abcdef")
            return String(hash.finalize().flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0f)]] })
        }
    }
}
