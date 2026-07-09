import Foundation

/// The full set of native and web surfaces the shell is currently hosting.
///
/// Decoded from the JSON produced by `owl_fresh_mojo_surface_tree_capture_surface_json`
/// and the `surfaceTreeChanged` event payload.
public struct ChromiumSurfaceTree: Codable, Sendable, Equatable {
    /// Monotonically increasing counter; bumped on every surface-tree mutation.
    public let generation: UInt64
    /// Every surface currently known to the shell, in Z order.
    public let surfaces: [ChromiumSurfaceInfo]

    /// Decodes a surface tree from its JSON string representation.
    public init(json: String) throws {
        self = try JSONDecoder().decode(ChromiumSurfaceTree.self, from: Data(json.utf8))
    }
}

/// One surface in the shell's surface tree: the main web view, a popup, a
/// native menu, a native file picker, or DevTools.
public struct ChromiumSurfaceInfo: Codable, Sendable, Equatable {
    /// The kind of content a surface hosts.
    public enum Kind: Int, Codable, Sendable {
        /// The primary web content surface.
        case webView = 0
        /// An HTML `<select>` popup rendered by the renderer.
        case popupWidget = 1
        /// A native (AppKit) context menu, e.g. for `<select>` or right-click.
        case nativeMenu = 2
        /// A native file picker dialog.
        case nativeFilePicker = 3
        /// The DevTools panel.
        case devTools = 4
        /// A surface kind not recognized by this build; the raw value is discarded.
        case unknown = -1

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(Int.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// Stable identifier for this surface, unique within a session.
    public let surfaceId: UInt64
    /// What this surface displays.
    public let kind: Kind
    /// X offset in points, relative to the web view's origin.
    public let x: Int32
    /// Y offset in points, relative to the web view's origin.
    public let y: Int32
    /// Width in points.
    public let width: UInt32
    /// Height in points.
    public let height: UInt32
    /// Whether the surface is currently visible.
    public let visible: Bool
    /// Plain-text labels for an HTML `<select>` popup's items.
    public let menuItems: [String]
    /// Rich item descriptions for a native context menu.
    public let nativeMenuItems: [ChromiumNativeMenuItem]
    /// The currently highlighted item index, or -1 if none.
    public let selectedIndex: Int32
    /// Whether a native menu should be right-aligned to its anchor.
    public let rightAligned: Bool
    /// The file picker's `<input type=file>` mode (e.g. `"open"`, `"save"`, `"folder"`).
    public let filePickerMode: String
    /// Whether the file picker allows selecting multiple files.
    public let filePickerAllowsMultiple: Bool
    /// Whether the file picker is selecting a folder to upload.
    public let filePickerUploadFolder: Bool
}

/// One item in a native (AppKit) context menu surface.
public struct ChromiumNativeMenuItem: Codable, Sendable, Equatable {
    /// The item's display text.
    public let label: String
    /// The item's tooltip text, if any.
    public let toolTip: String
    /// Whether the item can be selected.
    public let enabled: Bool
    /// Whether this item is a visual separator rather than a selectable entry.
    public let separator: Bool
    /// Whether this item starts a checkable group.
    public let group: Bool
}
