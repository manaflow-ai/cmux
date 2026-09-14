import CmuxFoundation
import SwiftUI

#if DEBUG
/// Native controls that update the same AppStorage bindings as the real footer.
struct CloudAnnouncementPreviewControls: View {
    @AppStorage(CloudAnnouncementPreviewStyle.selectionKey)
    private var selectedStyle = CloudAnnouncementPreviewStyle.notificationRow.rawValue
    @AppStorage(CloudAnnouncementPreviewStyle.visibilityKey)
    private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "debug.cloudAnnouncement.description", defaultValue: "Compare the four treatments in the sidebar of your terminal window."))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(CloudAnnouncementPreviewStyle.allCases) { style in
                    option(style)
                }
            }

            Divider()

            Toggle(
                String(localized: "debug.cloudAnnouncement.visible", defaultValue: "Show announcement in sidebar"),
                isOn: $isVisible
            )
            .accessibilityIdentifier("CloudAnnouncementVisible")

            HStack {
                Button(String(localized: "debug.cloudAnnouncement.replay", defaultValue: "Show again")) {
                    isVisible = true
                }
                .accessibilityIdentifier("CloudAnnouncementReplay")

                Button(String(localized: "sidebar.cloudAnnouncement.dismiss", defaultValue: "Dismiss announcement")) {
                    isVisible = false
                }
                .accessibilityIdentifier("CloudAnnouncementPreviewDismiss")
            }
        }
        .padding(20)
        .frame(width: 380)
        .accessibilityIdentifier("CloudAnnouncementPreviewControls")
    }

    private func option(_ style: CloudAnnouncementPreviewStyle) -> some View {
        Button {
            selectedStyle = style.rawValue
            isVisible = true
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selectedStyle == style.rawValue ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedStyle == style.rawValue ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title)
                        .cmuxFont(size: 12, weight: .medium)
                    Text(style.detail)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedStyle == style.rawValue ? Color.accentColor.opacity(0.07) : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedStyle == style.rawValue ? .isSelected : [])
        .accessibilityIdentifier("CloudAnnouncementChoose.\(style.rawValue)")
    }
}
#endif
