import SwiftUI

/// Drives the "flash the navigated-to row" affordance that the legacy
/// in-app settings window had and the SPM package initially dropped.
///
/// When the user clicks a search hit in the sidebar, the detail scroll
/// snaps the matching row to the vertical center *and* the row pulses a
/// rounded accent-colored border for a few seconds so the eye can find
/// it. The pulse is owned by ``SettingsSearchHighlightState`` (set on
/// the settings root) and read by every ``SettingsCardRow`` through the
/// environment; a row participates by tagging itself with
/// ``SwiftUI/View/settingsSearchAnchors(_:)``.

/// The currently-highlighted anchor plus a monotonic token and the
/// instant the pulse began. `token` changes on every navigation so
/// re-navigating to the same row restarts the animation even when the
/// anchor id is unchanged; `startedAt` seeds the `TimelineView` fade.
// Intentionally `internal`, not `public`: the legacy in-app settings
// (`Sources/SettingsNavigation.swift`) declares a same-named
// `SettingsSearchHighlightState` plus matching `View` /
// `EnvironmentValues` extensions. The app target imports this package, so
// a `public` surface here collides with the legacy one and makes every
// unqualified use ambiguous. Nothing outside this package consumes these
// symbols, so keeping them internal removes them from the host namespace.
struct SettingsSearchHighlightState: Equatable, Sendable {
    let anchorID: String?
    let token: Int
    let startedAt: Date?

    init(anchorID: String?, token: Int, startedAt: Date?) {
        self.anchorID = anchorID
        self.token = token
        self.startedAt = startedAt
    }
}

private struct SettingsSearchHighlightStateKey: EnvironmentKey {
    static let defaultValue = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)
}

extension EnvironmentValues {
    /// The active search-result highlight. Defaults to "nothing
    /// highlighted" so rows render inert outside the settings window.
    var settingsSearchHighlightState: SettingsSearchHighlightState {
        get { self[SettingsSearchHighlightStateKey.self] }
        set { self[SettingsSearchHighlightStateKey.self] = newValue }
    }
}

/// Resolves a row's dotted cmux.json path (declared via
/// ``SettingsConfigurationReview``) to the stable sidebar/search anchor
/// id the navigation layer scrolls to and highlights. Injected from the
/// settings root, which owns the built ``SettingsSearchIndex``.
private struct SettingsSearchIndexKey: EnvironmentKey {
    static let defaultValue: SettingsSearchIndex? = nil
}

extension EnvironmentValues {
    /// The settings search index, used by ``SettingsCardRow`` to map its
    /// declared config paths to scroll/highlight anchor ids. `nil` when
    /// a row is rendered outside the settings window (e.g. previews), in
    /// which case the row simply doesn't anchor.
    var settingsSearchIndex: SettingsSearchIndex? {
        get { self[SettingsSearchIndexKey.self] }
        set { self[SettingsSearchIndexKey.self] = newValue }
    }
}

extension View {
    /// Tags this view with a single search anchor. Convenience over
    /// ``settingsSearchAnchors(_:)`` for the common one-path row.
    @ViewBuilder
    func settingsSearchAnchor(_ anchorID: String?) -> some View {
        if let anchorID {
            settingsSearchAnchors([anchorID])
        } else {
            self
        }
    }

    /// Makes this view both `scrollTo`-addressable (via `.id` on the
    /// first anchor) and eligible for the search-result highlight pulse
    /// when any of `anchorIDs` matches the active highlight state.
    @ViewBuilder
    func settingsSearchAnchors(_ anchorIDs: [String]) -> some View {
        let filteredAnchorIDs = anchorIDs.filter { !$0.isEmpty }
        if let primaryAnchorID = filteredAnchorIDs.first {
            self
                .id(primaryAnchorID)
                .modifier(SettingsSearchHighlightModifier(anchorIDs: filteredAnchorIDs))
        } else {
            self
        }
    }
}

/// Renders the pulsing accent border behind a row while it is the
/// active search-navigation target. A `TimelineView(.animation)` drives
/// the fade curve from `startedAt` so the highlight ramps in, holds,
/// then fades out without any timer or `Task.sleep` in app code.
private struct SettingsSearchHighlightModifier: ViewModifier {
    @Environment(\.settingsSearchHighlightState) private var highlightState
    let anchorIDs: [String]

    private func matches(_ state: SettingsSearchHighlightState) -> Bool {
        guard let anchorID = state.anchorID else { return false }
        return anchorIDs.contains(anchorID)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if matches(highlightState) {
                    TimelineView(.animation) { context in
                        let opacity = highlightOpacity(at: context.date, for: highlightState)
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(opacity * 0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentColor.opacity(opacity), lineWidth: 2.5)
                            )
                            .shadow(color: Color.accentColor.opacity(opacity * 0.24), radius: 8, x: 0, y: 0)
                    }
                    // Restart the animation when the user re-navigates to
                    // the same anchor: a changing token forces a fresh
                    // TimelineView identity so `startedAt` re-seeds.
                    .id(highlightState.token)
                }
            }
    }

    private func highlightOpacity(at date: Date, for state: SettingsSearchHighlightState) -> Double {
        guard matches(state), let startedAt = state.startedAt else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        if elapsed < 0.14 {
            return max(0, min(1, elapsed / 0.14))
        }
        if elapsed < 5 {
            return 1
        }
        if elapsed < 5.9 {
            return max(0, 1 - ((elapsed - 5) / 0.9))
        }
        return 0
    }
}
