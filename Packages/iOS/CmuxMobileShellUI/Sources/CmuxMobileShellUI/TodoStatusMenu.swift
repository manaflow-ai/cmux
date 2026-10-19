import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Tinted status-lane chip and picker for the native todo surface header.
struct TodoStatusMenu: View {
    let status: MobileTodoStatus
    let statusHidden: Bool
    let isEnabled: Bool
    let setStatus: (MobileTodoStatus?) -> Void

    var body: some View {
        Menu {
            Section(L10n.string("mobile.todo.status.menuTitle", defaultValue: "Status")) {
                Button {
                    setStatus(nil)
                } label: {
                    Label(
                        L10n.string("mobile.todo.status.automatic", defaultValue: "Automatic"),
                        systemImage: "sparkle"
                    )
                }
                ForEach(MobileTodoStatus.allCases, id: \.self) { lane in
                    Toggle(isOn: Binding(
                        get: { !statusHidden && lane == status },
                        set: { _ in setStatus(lane) }
                    )) {
                        Label(lane.displayName, systemImage: lane.systemImage)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chipSystemImage)
                    .font(.caption.weight(.semibold))
                // The chip is sized to the widest possible title up front, so
                // switching lanes (or the menu's first presentation) never
                // clips the label while the capsule resizes.
                ZStack {
                    ForEach(Self.sizingTitles, id: \.self) { title in
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .hidden()
                    }
                    Text(chipTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(chipTint)
            .background(Capsule().fill(chipTint.opacity(0.15)))
            .contentShape(Capsule())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(L10n.string("mobile.todo.status.choose", defaultValue: "Choose status"))
        .accessibilityValue(chipTitle)
    }

    private var chipTitle: String {
        statusHidden
            ? L10n.string("mobile.todo.status.hidden", defaultValue: "No Status")
            : status.displayName
    }

    private var chipSystemImage: String {
        statusHidden ? "circle.slash" : status.systemImage
    }

    private var chipTint: Color {
        statusHidden ? .secondary : status.tint
    }

    /// Every title the chip can present, for width reservation.
    static let sizingTitles: [String] =
        MobileTodoStatus.allCases.map(\.displayName)
            + [L10n.string("mobile.todo.status.hidden", defaultValue: "No Status")]
}
