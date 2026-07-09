public import CmuxBrowser
public import SwiftUI
import AppKit
#if DEBUG
import CMUXDebugLog
#endif

/// The omnibar suggestions popup list: a squircle popover of search/navigate/
/// history/tab/remote suggestion rows with a selected-row highlight, an optional
/// trailing badge, and a loading spinner for remote suggestions.
///
/// Renders from already-resolved values (the engine name, the suggestion list,
/// the selected index, the loading/enabled flags) and routes commit/highlight
/// through plain closures. The accessibility label is resolved app-side and
/// passed in because `String(localized:)` must bind to the app bundle, not this
/// package's bundle. The omnibar text-field host and suggestion commit/delete
/// logic stay app-side; this view only draws the list.
public struct OmnibarSuggestionsView: View {
    let engineName: String
    let items: [OmnibarSuggestion]
    let badges: [String?]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let accessibilityLabel: String
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Creates the suggestions popup from values resolved app-side.
    ///
    /// `badges` is index-aligned with `items`; each entry is the pre-localized
    /// trailing badge for that row (resolved app-side because the badge text
    /// binds to the app bundle's string catalog) or `nil` for no badge.
    public init(
        engineName: String,
        items: [OmnibarSuggestion],
        badges: [String?],
        selectedIndex: Int,
        isLoadingRemoteSuggestions: Bool,
        searchSuggestionsEnabled: Bool,
        accessibilityLabel: String,
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping (Int) -> Void
    ) {
        self.engineName = engineName
        self.items = items
        self.badges = badges
        self.selectedIndex = selectedIndex
        self.isLoadingRemoteSuggestions = isLoadingRemoteSuggestions
        self.searchSuggestionsEnabled = searchSuggestionsEnabled
        self.accessibilityLabel = accessibilityLabel
        self.onCommit = onCommit
        self.onHighlight = onHighlight
    }

    // Keep radii below half of the smallest rendered heights so this keeps a
    // squircle silhouette instead of auto-clamping into a capsule.
    private static let popupCornerRadius: CGFloat = 12
    private static let rowHighlightCornerRadius: CGFloat = 9
    private static let singleLineRowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 1
    private static let topInset: CGFloat = 3
    private static let bottomInset: CGFloat = 3
    private static let maxPopupHeight: CGFloat = 560

    private var popupCornerRadius: CGFloat { Self.popupCornerRadius }
    private var rowHighlightCornerRadius: CGFloat { Self.rowHighlightCornerRadius }
    private var singleLineRowHeight: CGFloat { Self.singleLineRowHeight }
    private var rowSpacing: CGFloat { Self.rowSpacing }
    private var topInset: CGFloat { Self.topInset }
    private var bottomInset: CGFloat { Self.bottomInset }
    private var horizontalInset: CGFloat { topInset }
    private var maxPopupHeight: CGFloat { Self.maxPopupHeight }

    private var totalRowCount: Int {
        max(1, items.count)
    }

    private func rowHeight(for item: OmnibarSuggestion) -> CGFloat {
        return singleLineRowHeight
    }

    private var contentHeight: CGFloat {
        let rowsHeight = items.isEmpty ? singleLineRowHeight : items.reduce(CGFloat(0)) { partial, item in
            partial + rowHeight(for: item)
        }
        let gaps = CGFloat(max(0, totalRowCount - 1))
        return rowsHeight + (gaps * rowSpacing) + topInset + bottomInset
    }

    private var minimumPopupHeight: CGFloat {
        singleLineRowHeight + topInset + bottomInset
    }

    private func snapToDevicePixels(_ value: CGFloat) -> CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var popupHeight: CGFloat {
        Self.popupHeight(for: items)
    }

    /// Computes the device-pixel-snapped popup height for a suggestion list, used
    /// both for the SwiftUI overlay frame and the AppKit portal-hosted placement.
    public static func popupHeight(for items: [OmnibarSuggestion]) -> CGFloat {
        let totalRowCount = max(1, items.count)
        let rowsHeight = items.isEmpty ? singleLineRowHeight : CGFloat(items.count) * singleLineRowHeight
        let gaps = CGFloat(max(0, totalRowCount - 1))
        let contentHeight = rowsHeight + (gaps * rowSpacing) + topInset + bottomInset
        let minimumPopupHeight = singleLineRowHeight + topInset + bottomInset
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let height = min(max(contentHeight, minimumPopupHeight), maxPopupHeight)
        return (height * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var isPointerDrivenSelectionEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private var shouldScroll: Bool {
        contentHeight > maxPopupHeight
    }

    private var listTextColor: Color {
        switch colorScheme {
        case .light:
            return Color(nsColor: .labelColor)
        case .dark:
            return Color.white.opacity(0.9)
        @unknown default:
            return Color(nsColor: .labelColor)
        }
    }

    private var badgeTextColor: Color {
        switch colorScheme {
        case .light:
            return Color(nsColor: .secondaryLabelColor)
        case .dark:
            return Color.white.opacity(0.72)
        @unknown default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var badgeBackgroundColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.06)
        case .dark:
            return Color.white.opacity(0.08)
        @unknown default:
            return Color.black.opacity(0.06)
        }
    }

    private var rowHighlightColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.07)
        case .dark:
            return Color.white.opacity(0.12)
        @unknown default:
            return Color.black.opacity(0.07)
        }
    }

    private var popupOverlayGradientColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color.white.opacity(0.55),
                Color.white.opacity(0.2),
            ]
        case .dark:
            return [
                Color.black.opacity(0.26),
                Color.black.opacity(0.14),
            ]
        @unknown default:
            return [
                Color.white.opacity(0.55),
                Color.white.opacity(0.2),
            ]
        }
    }

    private var popupBorderGradientColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color.white.opacity(0.65),
                Color.black.opacity(0.12),
            ]
        case .dark:
            return [
                Color.white.opacity(0.22),
                Color.white.opacity(0.06),
            ]
        @unknown default:
            return [
                Color.white.opacity(0.65),
                Color.black.opacity(0.12),
            ]
        }
    }

    private var popupShadowColor: Color {
        switch colorScheme {
        case .light:
            return Color.black.opacity(0.18)
        case .dark:
            return Color.black.opacity(0.45)
        @unknown default:
            return Color.black.opacity(0.18)
        }
    }

    private func suggestionBadge(_ badge: String) -> some View {
        Text(badge)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(badgeTextColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(badgeBackgroundColor)
            )
    }

    @ViewBuilder
    private func suggestionRowLabel(for item: OmnibarSuggestion, badge: String?, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(item.listText)
                .font(.system(size: 11))
                .foregroundStyle(listTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if let badge {
                suggestionBadge(badge)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(
            maxWidth: .infinity,
            minHeight: rowHeight(for: item),
            maxHeight: rowHeight(for: item),
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: rowHighlightCornerRadius, style: .continuous)
                .fill(
                    isSelected
                        ? rowHighlightColor
                        : Color.clear
                )
        )
    }

    private func handleSuggestionCommit(_ item: OmnibarSuggestion, idx: Int) {
        #if DEBUG
        let suggestionKind: String = {
            switch item.kind {
            case .search:
                return "search"
            case .navigate:
                return "navigate"
            case .history:
                return "history"
            case .switchToTab:
                return "switchToTab"
            case .remote:
                return "remote"
            }
        }()
        logDebugEvent("browser.suggestionClick index=\(idx) kind=\(suggestionKind) textBytes=\(item.listText.utf8.count)")
        #endif
        onCommit(item)
    }

    @ViewBuilder
    private func suggestionRow(idx: Int, item: OmnibarSuggestion) -> some View {
        Button {
            handleSuggestionCommit(item, idx: idx)
        } label: {
            suggestionRowLabel(
                for: item,
                badge: idx < badges.count ? badges[idx] : nil,
                isSelected: idx == selectedIndex
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("BrowserOmnibarSuggestions.Row.\(idx)")
        .accessibilityValue(
            idx == selectedIndex
                ? "selected \(item.listText)"
                : item.listText
        )
        .onHover { hovering in
            if hovering, idx != selectedIndex, isPointerDrivenSelectionEvent {
                onHighlight(idx)
            }
        }
        .animation(.none, value: selectedIndex)
    }

    @ViewBuilder
    private var rowsView: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                suggestionRow(idx: idx, item: item)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    public var body: some View {
        Group {
            if shouldScroll {
                ScrollView {
                    rowsView
                }
            } else {
                rowsView
            }
        }
        .frame(height: popupHeight, alignment: .top)
        .overlay(alignment: .topTrailing) {
            if searchSuggestionsEnabled, isLoadingRemoteSuggestions {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 7)
                    .padding(.trailing, 14)
                    .opacity(0.75)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: popupOverlayGradientColors,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: popupBorderGradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .shadow(color: popupShadowColor, radius: 20, y: 10)
        .contentShape(RoundedRectangle(cornerRadius: popupCornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityRespondsToUserInteraction(true)
        .accessibilityIdentifier("BrowserOmnibarSuggestions")
        .accessibilityLabel(accessibilityLabel)
    }
}
