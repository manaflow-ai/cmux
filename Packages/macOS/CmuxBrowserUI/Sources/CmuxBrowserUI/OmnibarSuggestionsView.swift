public import CmuxBrowser
public import SwiftUI

import AppKit
#if DEBUG
internal import CMUXDebugLog
#endif

/// The omnibar suggestion popup rendered beneath the browser address bar.
///
/// Renders one row per ``OmnibarSuggestion`` (search, navigate, history,
/// switch-to-tab, or remote prediction), highlights the selected row, shows a
/// loading spinner while remote suggestions resolve, and reports commit and
/// highlight intents through closures. ``popupHeight(for:)`` is exposed so the
/// owning chrome can reserve the exact device-pixel-snapped height before the
/// view mounts.
public struct OmnibarSuggestionsView: View {
    private let engineName: String
    private let items: [OmnibarSuggestion]
    private let selectedIndex: Int
    private let isLoadingRemoteSuggestions: Bool
    private let searchSuggestionsEnabled: Bool
    private let onCommit: (OmnibarSuggestion) -> Void
    private let onHighlight: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Creates the omnibar suggestion popup.
    /// - Parameters:
    ///   - engineName: The active search engine name (used for badges/telemetry).
    ///   - items: The ordered suggestions to render.
    ///   - selectedIndex: Index of the highlighted row.
    ///   - isLoadingRemoteSuggestions: Whether remote suggestions are in flight.
    ///   - searchSuggestionsEnabled: Whether remote search suggestions are enabled.
    ///   - onCommit: Invoked when a row is activated.
    ///   - onHighlight: Invoked when a row should become the selection.
    public init(
        engineName: String,
        items: [OmnibarSuggestion],
        selectedIndex: Int,
        isLoadingRemoteSuggestions: Bool,
        searchSuggestionsEnabled: Bool,
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping (Int) -> Void
    ) {
        self.engineName = engineName
        self.items = items
        self.selectedIndex = selectedIndex
        self.isLoadingRemoteSuggestions = isLoadingRemoteSuggestions
        self.searchSuggestionsEnabled = searchSuggestionsEnabled
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

    /// Computes the device-pixel-snapped popup height for the given suggestions,
    /// clamped between a single-row minimum and the maximum popup height.
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

    @ViewBuilder
    private var rowsView: some View {
        VStack(spacing: rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
            Button {
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
                CMUXDebugLog.logDebugEvent("browser.suggestionClick index=\(idx) kind=\(suggestionKind) textBytes=\(item.listText.utf8.count)")
                #endif
                onCommit(item)
            } label: {
                HStack(spacing: 6) {
                        Text(item.listText)
                            .font(.system(size: 11))
                            .foregroundStyle(listTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let badge = item.trailingBadgeText {
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
                                idx == selectedIndex
                                    ? rowHighlightColor
                                    : Color.clear
                            )
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
        .accessibilityLabel(String(localized: "browser.addressBarSuggestions", defaultValue: "Address bar suggestions", bundle: .main))
    }
}
