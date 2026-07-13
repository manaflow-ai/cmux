#if DEBUG
import SwiftUI

/// Renders one fixture conversation entry in its role-specific Meridian treatment.
struct MeridianChatEntryView: View {
    let entry: GalleryChatEntry

    @Environment(\.colorScheme) private var colorScheme
    @State private var outputExpanded = true

    var body: some View {
        switch entry.role {
        case .user:
            userMessage
        case .agent:
            agentMessage
        case .tool:
            toolCard
        case .approval:
            approvalCard
        }
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(theme.label)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    theme.secondaryBackground,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            Text(entry.timeText)
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private var agentMessage: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.text)
                .font(.body)
                .foregroundStyle(theme.label)
            Text(entry.timeText)
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 28)
    }

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.headline)
                .foregroundStyle(theme.label)

            if let command = entry.toolCommand {
                Text(command)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let output = entry.toolOutput {
                DisclosureGroup("Output", isExpanded: $outputExpanded) {
                    Text(output)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .font(.subheadline)
                .tint(theme.secondaryLabel)
            }

            Text(entry.timeText)
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .padding(16)
        .background(
            theme.secondaryBackground,
            in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        )
    }

    private var approvalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Approval requested", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(theme.needsYou)

            Text(entry.question ?? entry.text)
                .font(.body)
                .foregroundStyle(theme.label)

            HStack(spacing: 12) {
                Button(DesignGalleryFixtures.approvalActions[1]) {}
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: 44)

                Button(DesignGalleryFixtures.approvalActions[0]) {}
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .tint(theme.accent)

            Text(entry.timeText)
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .padding(16)
        .background(
            theme.secondaryBackground,
            in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        )
    }
}
#endif
