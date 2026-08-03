import CmuxExtensionKit

enum SummaryPill {
    static func node(value: String, label: String) -> CmuxSidebarPresentationNode {
        .panel(.inset(
            CmuxSidebarPresentationInsets(top: 5, leading: 8, bottom: 5, trailing: 8),
            .stack(axis: .vertical, spacing: 1, children: [
                .text(value, style: CmuxSidebarPresentationTextStyle(size: 13, weight: .semibold)),
                .text(label, style: CmuxSidebarPresentationTextStyle(size: 9, weight: .medium, color: .secondary)),
            ])
        ))
    }
}
