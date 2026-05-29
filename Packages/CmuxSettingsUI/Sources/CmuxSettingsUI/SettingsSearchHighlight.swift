import SwiftUI

public struct SettingsSearchHighlightState: Equatable, Sendable {
    public let anchorID: String?
    public let token: Int
    public let startedAt: Date?

    public init(anchorID: String?, token: Int, startedAt: Date?) {
        self.anchorID = anchorID
        self.token = token
        self.startedAt = startedAt
    }
}

private struct SettingsSearchHighlightStateKey: EnvironmentKey {
    static let defaultValue = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)
}

public extension EnvironmentValues {
    var settingsSearchHighlightState: SettingsSearchHighlightState {
        get { self[SettingsSearchHighlightStateKey.self] }
        set { self[SettingsSearchHighlightStateKey.self] = newValue }
    }
}

public extension View {
    @ViewBuilder
    func settingsSearchAnchor(_ anchorID: String?) -> some View {
        if let anchorID {
            settingsSearchAnchors([anchorID])
        } else {
            self
        }
    }

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
