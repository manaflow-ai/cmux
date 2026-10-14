#if os(iOS)
import SwiftUI

/// One hue plus system grays. Status is told apart by shape (spinner, filled
/// dot, ring, check), not by color, so the list never turns into a rainbow.
public struct WorkspacesTheme: Sendable {
    /// The only accent: needs-you marks, badges that block, primary buttons.
    public var accent: Color
    public var label: Color = .primary
    public var secondary: Color = .secondary
    public var fill: Color = Color(uiColor: .secondarySystemFill)
    public var groupedBackground: Color = Color(uiColor: .secondarySystemBackground)

    public init(accent: Color = Color(red: 0.03, green: 0.41, blue: 0.80)) {
        self.accent = accent
    }
}

private struct WorkspacesThemeKey: EnvironmentKey {
    static let defaultValue = WorkspacesTheme()
}

public extension EnvironmentValues {
    var workspacesTheme: WorkspacesTheme {
        get { self[WorkspacesThemeKey.self] }
        set { self[WorkspacesThemeKey.self] = newValue }
    }
}

public extension View {
    func workspacesTheme(_ theme: WorkspacesTheme) -> some View {
        environment(\.workspacesTheme, theme).tint(theme.accent)
    }
}

/// The trailing status mark on a workspace.
struct StatusMark: View {
    let status: WorkspaceStatus
    @Environment(\.workspacesTheme) private var theme

    var body: some View {
        Group {
            switch status {
            case .working:
                ProgressView().controlSize(.mini).tint(theme.secondary)
            case .needsAttention:
                Circle().fill(theme.accent).frame(width: 9, height: 9)
            case .review:
                Circle().strokeBorder(theme.accent, lineWidth: 1.75).frame(width: 10, height: 10)
            case .done:
                Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(theme.secondary)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(status.label)
    }
}

/// Unread count; accent only when something is blocking.
struct UnreadBadge: View {
    let count: Int
    let blocking: Bool
    @Environment(\.workspacesTheme) private var theme

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(blocking ? Color.white : theme.label)
                .padding(.horizontal, 6)
                .frame(minWidth: 19, minHeight: 19)
                .background(Capsule().fill(blocking ? theme.accent : theme.fill))
                .accessibilityLabel("\(count) unread")
        }
    }
}

extension WorkspaceStatus {
    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsAttention: "Needs you"
        case .review: "Ready for review"
        case .done: "Done"
        }
    }
}

extension WorkspaceTab.Kind {
    var systemImage: String {
        switch self {
        case .chief: "sparkle"
        case .terminal: "terminal"
        case .browser: "globe"
        }
    }
}
#endif
