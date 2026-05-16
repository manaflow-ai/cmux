import Foundation
import SwiftUI

/// Controls how tab content views are managed when switching between tabs
public enum ContentViewLifecycle: Sendable {
    /// Only the selected tab's content view is rendered. Other tabs' views are
    /// destroyed and recreated when selected. This is memory efficient but loses
    /// view state like scroll position, @State variables, and focus.
    case recreateOnSwitch

    /// All tab content views are kept in the view hierarchy, with non-selected tabs
    /// hidden. This preserves all view state (scroll position, @State, focus, etc.)
    /// at the cost of higher memory usage.
    case keepAllAlive
}

/// Controls the position where new tabs are created
public enum NewTabPosition: Sendable {
    /// Insert the new tab after the currently focused tab,
    /// or at the end if there are no focused tabs.
    case current

    /// Insert the new tab at the end of the tab list.
    case end
}

/// Configuration for the split tab bar appearance and behavior
public struct WorkspaceLayoutConfiguration: Sendable {

    // MARK: - Behavior

    /// Whether to allow creating splits
    public var allowSplits: Bool

    /// Whether to allow closing tabs
    public var allowCloseTabs: Bool

    /// Whether to allow closing the last pane
    public var allowCloseLastPane: Bool

    /// Whether to allow drag & drop reordering of tabs
    public var allowTabReordering: Bool

    /// Whether to allow moving tabs between panes
    public var allowCrossPaneTabMove: Bool

    /// Whether to automatically close empty panes
    public var autoCloseEmptyPanes: Bool

    /// Controls how tab content views are managed when switching tabs
    public var contentViewLifecycle: ContentViewLifecycle

    /// Controls where new tabs are inserted in the tab list
    public var newTabPosition: NewTabPosition

    // MARK: - Appearance

    /// SurfaceTab bar appearance customization
    public var appearance: Appearance

    // MARK: - Presets

    public static let `default` = WorkspaceLayoutConfiguration()

    public static let singlePane = WorkspaceLayoutConfiguration(
        allowSplits: false,
        allowCloseLastPane: false
    )

    public static let readOnly = WorkspaceLayoutConfiguration(
        allowSplits: false,
        allowCloseTabs: false,
        allowTabReordering: false,
        allowCrossPaneTabMove: false
    )

    // MARK: - Initializer

    public init(
        allowSplits: Bool = true,
        allowCloseTabs: Bool = true,
        allowCloseLastPane: Bool = false,
        allowTabReordering: Bool = true,
        allowCrossPaneTabMove: Bool = true,
        autoCloseEmptyPanes: Bool = true,
        contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch,
        newTabPosition: NewTabPosition = .current,
        appearance: Appearance = .default
    ) {
        self.allowSplits = allowSplits
        self.allowCloseTabs = allowCloseTabs
        self.allowCloseLastPane = allowCloseLastPane
        self.allowTabReordering = allowTabReordering
        self.allowCrossPaneTabMove = allowCrossPaneTabMove
        self.autoCloseEmptyPanes = autoCloseEmptyPanes
        self.contentViewLifecycle = contentViewLifecycle
        self.newTabPosition = newTabPosition
        self.appearance = appearance
    }
}

// MARK: - Appearance Configuration

extension WorkspaceLayoutConfiguration {
    public struct SplitActionButton: Sendable, Codable, Hashable, Identifiable {
        public enum Icon: Sendable, Codable, Hashable {
            case systemImage(String)
            case emoji(String, scale: Double = 1)
            case imageData(Data)

            private enum CodingKeys: String, CodingKey {
                case type
                case name
                case value
                case data
                case scale
            }

            public init(from decoder: Decoder) throws {
                if let value = try? decoder.singleValueContainer().decode(String.self) {
                    self = .systemImage(value)
                    return
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "systemImage", "symbol", "sfSymbol":
                    self = .systemImage(try container.decode(String.self, forKey: .name))
                case "emoji":
                    self = .emoji(
                        try container.decode(String.self, forKey: .value),
                        scale: try Self.emojiScale(in: container)
                    )
                case "imageData":
                    self = .imageData(try container.decode(Data.self, forKey: .data))
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unknown split action button icon type '\(type)'"
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .systemImage(let name):
                    try container.encode("systemImage", forKey: .type)
                    try container.encode(name, forKey: .name)
                case .emoji(let value, let scale):
                    try container.encode("emoji", forKey: .type)
                    try container.encode(value, forKey: .value)
                    if scale != 1 {
                        try container.encode(scale, forKey: .scale)
                    }
                case .imageData(let data):
                    try container.encode("imageData", forKey: .type)
                    try container.encode(data, forKey: .data)
                }
            }

            private static func emojiScale(in container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
                let scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
                guard scale.isFinite, scale > 0 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .scale,
                        in: container,
                        debugDescription: "Emoji icon scale must be a positive number"
                    )
                }
                return scale
            }
        }

        public enum Action: Sendable, Codable, Hashable {
            case newTerminal
            case newBrowser
            case splitRight
            case splitDown
            case custom(String)

            private enum CodingKeys: String, CodingKey {
                case type
                case identifier
            }

            public var rawValue: String {
                switch self {
                case .newTerminal:
                    return "newTerminal"
                case .newBrowser:
                    return "newBrowser"
                case .splitRight:
                    return "splitRight"
                case .splitDown:
                    return "splitDown"
                case .custom(let identifier):
                    return identifier
                }
            }

            public init(from decoder: Decoder) throws {
                if let container = try? decoder.singleValueContainer(),
                   let value = try? container.decode(String.self) {
                    self = Self.action(for: value)
                    return
                }

                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                if type == "custom" {
                    self = .custom(try container.decode(String.self, forKey: .identifier))
                } else {
                    self = Self.action(for: type)
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .custom(let identifier):
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode("custom", forKey: .type)
                    try container.encode(identifier, forKey: .identifier)
                default:
                    var container = encoder.singleValueContainer()
                    try container.encode(rawValue)
                }
            }

            private static func action(for value: String) -> Action {
                switch value {
                case "newTerminal":
                    return .newTerminal
                case "newBrowser":
                    return .newBrowser
                case "splitRight":
                    return .splitRight
                case "splitDown":
                    return .splitDown
                default:
                    return .custom(value)
                }
            }
        }

        public var id: String
        public var icon: Icon
        public var tooltip: String?
        public var action: Action

        public var systemImage: String {
            if case .systemImage(let name) = icon {
                return name
            }
            return "questionmark.circle"
        }

        public init(
            id: String,
            systemImage: String,
            tooltip: String? = nil,
            action: Action
        ) {
            self.init(
                id: id,
                icon: .systemImage(systemImage),
                tooltip: tooltip,
                action: action
            )
        }

        public init(
            id: String,
            icon: Icon,
            tooltip: String? = nil,
            action: Action
        ) {
            self.id = id
            self.icon = icon
            self.tooltip = tooltip
            self.action = action
        }

        public static let newTerminal = SplitActionButton(
            id: "newTerminal",
            systemImage: "terminal",
            action: .newTerminal
        )
        public static let newBrowser = SplitActionButton(
            id: "newBrowser",
            systemImage: "globe",
            action: .newBrowser
        )
        public static let splitRight = SplitActionButton(
            id: "splitRight",
            systemImage: "square.split.2x1",
            action: .splitRight
        )
        public static let splitDown = SplitActionButton(
            id: "splitDown",
            systemImage: "square.split.1x2",
            action: .splitDown
        )

        /// Built-in split actions shown by default. Hosts can replace this list with custom buttons.
        public static let defaults: [SplitActionButton] = [
            .newTerminal,
            .newBrowser,
            .splitRight,
            .splitDown
        ]
    }

    public struct SplitButtonTooltips: Sendable, Equatable {
        public var newTerminal: String
        public var newBrowser: String
        public var splitRight: String
        public var splitDown: String

        public static let `default` = SplitButtonTooltips()

        public init(
            newTerminal: String = "New Terminal",
            newBrowser: String = "New Browser",
            splitRight: String = "Split Right",
            splitDown: String = "Split Down"
        ) {
            self.newTerminal = newTerminal
            self.newBrowser = newBrowser
            self.splitRight = splitRight
            self.splitDown = splitDown
        }
    }

    public struct Appearance: Sendable {
        public enum SplitButtonBackdropStyle: Int, CaseIterable, Sendable {
            case precompositedPaneBackground = 0
            case opaquePaneBackground = 1
            case opaqueBarBackground = 2
            case windowBackground = 3
            case controlBackground = 4
            case precompositedBarBackground = 5
            case translucentChrome = 6
            case hidden = 7
        }

        public struct SplitButtonBackdropEffect: Sendable {
            public var style: SplitButtonBackdropStyle
            public var fadeWidth: CGFloat
            public var contentFadeWidth: CGFloat
            public var solidWidth: CGFloat
            public var solidSurfaceWidthAdjustment: CGFloat
            public var separatorFadeWidth: CGFloat?
            public var fadeRampStartFraction: CGFloat
            public var leadingOpacity: CGFloat
            public var trailingOpacity: CGFloat
            public var contentOcclusionFraction: CGFloat
            public var masksTabContent: Bool

            public init(
                style: SplitButtonBackdropStyle = .translucentChrome,
                fadeWidth: CGFloat = 136,
                contentFadeWidth: CGFloat = 42,
                solidWidth: CGFloat = 2,
                solidSurfaceWidthAdjustment: CGFloat = 0,
                separatorFadeWidth: CGFloat? = nil,
                fadeRampStartFraction: CGFloat = 0.80,
                leadingOpacity: CGFloat = 0,
                trailingOpacity: CGFloat = 0.80,
                contentOcclusionFraction: CGFloat = 1.0,
                masksTabContent: Bool = true
            ) {
                self.style = style
                self.fadeWidth = max(0, fadeWidth)
                self.contentFadeWidth = max(0, contentFadeWidth)
                self.solidWidth = max(0, solidWidth)
                self.solidSurfaceWidthAdjustment = solidSurfaceWidthAdjustment.isFinite
                    ? solidSurfaceWidthAdjustment
                    : 0
                self.separatorFadeWidth = separatorFadeWidth.map { max(0, $0) }
                self.fadeRampStartFraction = min(max(0, fadeRampStartFraction), 0.95)
                self.leadingOpacity = min(max(0, leadingOpacity), 1)
                self.trailingOpacity = min(max(0, trailingOpacity), 1)
                self.contentOcclusionFraction = min(max(0, contentOcclusionFraction), 1)
                self.masksTabContent = masksTabContent
            }

            public static let `default` = SplitButtonBackdropEffect()
        }

        public struct ChromeColors: Sendable {
            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for general chrome backgrounds.
            /// When unset, CMUXLayout uses native system colors.
            public var backgroundHex: String?

            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for the tab bar's resolved surface.
            /// When unset, CMUXLayout falls back to `backgroundHex`.
            public var tabBarBackgroundHex: String?

            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for the split action button backdrop.
            /// When unset, CMUXLayout falls back to `tabBarBackgroundHex`, then `backgroundHex`.
            public var splitButtonBackdropHex: String?

            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for the split pane background.
            /// When unset, CMUXLayout falls back to `backgroundHex`.
            public var paneBackgroundHex: String?

            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for separators/dividers.
            /// When unset, CMUXLayout derives separators from the chrome background.
            public var borderHex: String?

            public init(
                backgroundHex: String? = nil,
                tabBarBackgroundHex: String? = nil,
                splitButtonBackdropHex: String? = nil,
                paneBackgroundHex: String? = nil,
                borderHex: String? = nil
            ) {
                self.backgroundHex = backgroundHex
                self.tabBarBackgroundHex = tabBarBackgroundHex
                self.splitButtonBackdropHex = splitButtonBackdropHex
                self.paneBackgroundHex = paneBackgroundHex
                self.borderHex = borderHex
            }
        }

        // MARK: - SurfaceTab Bar

        /// Height of the tab bar
        public var tabBarHeight: CGFloat

        // MARK: - Tabs

        /// Minimum width of a tab
        public var tabMinWidth: CGFloat

        /// Maximum width of a tab
        public var tabMaxWidth: CGFloat

        /// Font size for tab titles in the surface tab bar
        public var tabTitleFontSize: CGFloat

        /// Spacing between tabs
        public var tabSpacing: CGFloat

        // MARK: - Split View

        /// Minimum width of a pane
        public var minimumPaneWidth: CGFloat

        /// Minimum height of a pane
        public var minimumPaneHeight: CGFloat

        /// Whether to show split buttons in the tab bar
        public var showSplitButtons: Bool

        /// Ordered action buttons shown in the tab bar when split buttons are enabled.
        /// Duplicate button ids are ignored, preserving the first matching button.
        public var splitButtons: [SplitActionButton] {
            didSet {
                splitButtons = Self.uniqueSplitButtons(splitButtons)
            }
        }

        /// When true, split buttons are only visible on hover
        public var splitButtonsOnHover: Bool

        /// Optional explicit backdrop style for the tab bar's right-side action buttons.
        /// When unset, CMUXLayout uses the host app's debug override if one is configured.
        public var splitButtonBackdropStyle: SplitButtonBackdropStyle?

        /// Optional explicit backdrop effect for the tab bar's right-side action buttons.
        /// This controls both the color strategy and how tab content is faded or clipped
        /// underneath the action-button region.
        public var splitButtonBackdropEffect: SplitButtonBackdropEffect?

        /// Extra leading inset for the tab bar (e.g. for traffic light buttons when sidebar is collapsed)
        public var tabBarLeadingInset: CGFloat

        /// Tooltip text for the tab bar's right-side action buttons
        public var splitButtonTooltips: SplitButtonTooltips

        // MARK: - Animations

        /// Duration of animations
        public var animationDuration: Double

        /// Whether to enable animations
        public var enableAnimations: Bool

        // MARK: - Theme Overrides

        /// Optional color overrides for tab/pane chrome.
        public var chromeColors: ChromeColors

        /// When true, the host app is trying to make all surfaces share the
        /// same backdrop. CMUXLayout should avoid local chrome color adjustments
        /// that would create visibly different translucent layers.
        public var usesSharedBackdrop: Bool

        // MARK: - Presets

        public static let `default` = Appearance()

        public static let compact = Appearance(
            tabBarHeight: 28,
            tabMinWidth: 100,
            tabMaxWidth: 160,
            tabTitleFontSize: 11
        )

        public static let spacious = Appearance(
            tabBarHeight: 38,
            tabMinWidth: 160,
            tabMaxWidth: 280,
            tabTitleFontSize: 11,
            tabSpacing: 2
        )

        // MARK: - Initializer

        public init(
            tabBarHeight: CGFloat = 30,
            tabMinWidth: CGFloat = 140,
            tabMaxWidth: CGFloat = 220,
            tabTitleFontSize: CGFloat = 11,
            tabSpacing: CGFloat = 0,
            minimumPaneWidth: CGFloat = 100,
            minimumPaneHeight: CGFloat = 100,
            showSplitButtons: Bool = true,
            splitButtons: [SplitActionButton] = SplitActionButton.defaults,
            splitButtonsOnHover: Bool = false,
            splitButtonBackdropStyle: SplitButtonBackdropStyle? = nil,
            splitButtonBackdropEffect: SplitButtonBackdropEffect? = nil,
            tabBarLeadingInset: CGFloat = 0,
            splitButtonTooltips: SplitButtonTooltips = .default,
            animationDuration: Double = 0.15,
            enableAnimations: Bool = true,
            chromeColors: ChromeColors = .init(),
            usesSharedBackdrop: Bool = false
        ) {
            self.tabBarHeight = tabBarHeight
            self.tabMinWidth = tabMinWidth
            self.tabMaxWidth = tabMaxWidth
            self.tabTitleFontSize = tabTitleFontSize
            self.tabSpacing = tabSpacing
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.showSplitButtons = showSplitButtons
            self.splitButtons = Self.uniqueSplitButtons(splitButtons)
            self.splitButtonsOnHover = splitButtonsOnHover
            self.splitButtonBackdropStyle = splitButtonBackdropStyle
            self.splitButtonBackdropEffect = splitButtonBackdropEffect
            self.tabBarLeadingInset = tabBarLeadingInset
            self.splitButtonTooltips = splitButtonTooltips
            self.animationDuration = animationDuration
            self.enableAnimations = enableAnimations
            self.chromeColors = chromeColors
            self.usesSharedBackdrop = usesSharedBackdrop
        }

        private static func uniqueSplitButtons(_ buttons: [SplitActionButton]) -> [SplitActionButton] {
            var seenIds = Set<String>()
            return buttons.filter { seenIds.insert($0.id).inserted }
        }
    }
}
