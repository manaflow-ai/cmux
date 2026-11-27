#if os(iOS) && DEBUG
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Debug-only CMUX Labs surface for tuning the workspace unread count badge:
/// how close it sits to the screen's left edge and the circle's diameter.
/// Both values persist through ``MobileDisplaySettings`` and apply live to the
/// real workspace list, so an experiment can be judged in place.
struct UnreadIndicatorLabView: View {
    @Environment(MobileDisplaySettings.self) private var displaySettings

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return Form {
            Section(L10n.string(
                "mobile.settings.unreadIndicatorLab.preview",
                defaultValue: "Preview"
            )) {
                ForEach(Self.sampleWorkspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        connectionStatus: .connected,
                        isSelected: false,
                        wrapWorkspaceTitles: false,
                        unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
                        unreadBadgeDiameter: displaySettings.unreadBadgeDiameter
                    )
                    .allowsHitTesting(false)
                }
            }

            Section {
                labSlider(
                    title: L10n.string(
                        "mobile.settings.unreadIndicatorLab.leftShift",
                        defaultValue: "Left Shift"
                    ),
                    value: $displaySettings.unreadIndicatorLeftShift,
                    range: MobileDisplaySettings.unreadIndicatorLeftShiftRange,
                    step: 0.5,
                    identifier: "MobileUnreadIndicatorLabLeftShift"
                )

                labSlider(
                    title: L10n.string(
                        "mobile.settings.unreadIndicatorLab.circleSize",
                        defaultValue: "Circle Size"
                    ),
                    value: $displaySettings.unreadBadgeDiameter,
                    range: MobileDisplaySettings.unreadBadgeDiameterRange,
                    step: 1,
                    identifier: "MobileUnreadIndicatorLabCircleSize"
                )

                Button(L10n.string(
                    "mobile.settings.unreadIndicatorLab.reset",
                    defaultValue: "Reset to Defaults"
                )) {
                    displaySettings.unreadIndicatorLeftShift =
                        MobileDisplaySettings.defaultUnreadIndicatorLeftShift
                    displaySettings.unreadBadgeDiameter =
                        MobileDisplaySettings.defaultUnreadBadgeDiameter
                }
                .accessibilityIdentifier("MobileUnreadIndicatorLabReset")
            } footer: {
                Text(L10n.string(
                    "mobile.settings.unreadIndicatorLab.footer",
                    defaultValue: "Higher Left Shift moves the badge closer to the screen edge. Both values persist on this device and apply live to the workspace list."
                ))
            }
        }
        .navigationTitle(L10n.string(
            "mobile.settings.unreadIndicatorLab",
            defaultValue: "Unread Indicator Lab"
        ))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func labSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.settings.unreadIndicatorLab.pointsFormat",
                        defaultValue: "%.1f pt"
                    ),
                    value.wrappedValue
                ))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
        .accessibilityIdentifier(identifier)
    }

    /// Static sample rows covering the badge's display cases: single digit,
    /// multi digit, unknown count (boolean-only Mac), and read.
    private static let sampleWorkspaces: [MobileWorkspacePreview] = [
        sampleWorkspace(id: "lab-one", name: "Fix login crash", unreadCount: 1),
        sampleWorkspace(id: "lab-three", name: "Build agents", unreadCount: 3),
        sampleWorkspace(id: "lab-many", name: "Review queue", unreadCount: 12),
        sampleWorkspace(id: "lab-unknown", name: "Boolean-only Mac", unreadCount: nil),
        sampleWorkspace(id: "lab-read", name: "Read workspace", unreadCount: 0),
    ]

    private static func sampleWorkspace(
        id: String,
        name: String,
        unreadCount: Int?
    ) -> MobileWorkspacePreview {
        let isUnread = unreadCount == nil || (unreadCount ?? 0) > 0
        return MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: name,
            previewText: "Agent finished, 334 tests passed",
            previewAt: Date(),
            lastActivityAt: Date(),
            hasUnread: isUnread,
            unreadCount: unreadCount,
            terminals: []
        )
    }
}
#endif
