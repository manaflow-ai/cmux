public import CMUXAgentLaunch
public import SwiftUI

/// Lists the tool prompts an agent is allowed to run after exiting plan mode.
/// Each row shows an optional tool tag followed by the prompt text.
///
/// The `feed.exitplan.*` localization key is resolved against the app's main
/// bundle (`bundle: .main`) so the app-side `.xcstrings` catalog and its
/// non-English translations keep working from the package.
public struct ExitPlanAllowedPromptsView: View {
    let prompts: [WorkstreamAllowedPrompt]

    public init(prompts: [WorkstreamAllowedPrompt]) {
        self.prompts = prompts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.purple.opacity(0.85))
                Text(String(localized: "feed.exitplan.allowedPrompts", defaultValue: "Allowed prompts", bundle: .main))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.purple.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !prompt.tool.isEmpty {
                            Text(prompt.tool)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.purple.opacity(0.14))
                                )
                        }
                        Text(prompt.prompt)
                            .font(.system(size: 11))
                            .foregroundColor(.primary.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.purple.opacity(0.06))
            )
        }
    }
}
