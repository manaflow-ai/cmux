#if os(iOS) && DEBUG
import CmuxMobileSupport
import SwiftUI

/// Debug-only selector that applies workspace-detail redesigns live.
struct WorkspaceDetailLabView: View {
    @Environment(MobileDisplaySettings.self) private var displaySettings

    var body: some View {
        List {
            Section(L10n.string(
                "mobile.settings.workspaceDetailLab.baselineSection",
                defaultValue: "Baseline"
            )) {
                WorkspaceDetailLabOptionRow(
                    number: nil,
                    title: L10n.string(
                        "mobile.settings.workspaceDetailLab.baseline",
                        defaultValue: "Current Layout"
                    ),
                    detail: L10n.string(
                        "mobile.settings.workspaceDetailLab.baseline.detail",
                        defaultValue: "Workspace actions stay in the title; terminals stay in the top-right stack menu."
                    ),
                    systemImage: "rectangle.stack",
                    isSelected: displaySettings.workspaceDetailLabVariant == nil,
                    action: { displaySettings.workspaceDetailLabVariant = nil }
                )
                .accessibilityIdentifier("MobileWorkspaceDetailLabBaseline")
            }

            Section {
                ForEach(WorkspaceDetailLabVariant.allCases.indices, id: \.self) { index in
                    let variant = WorkspaceDetailLabVariant.allCases[index]
                    WorkspaceDetailLabOptionRow(
                        number: index + 1,
                        title: title(for: variant),
                        detail: detail(for: variant),
                        systemImage: variant.systemImage,
                        isSelected: displaySettings.workspaceDetailLabVariant == variant,
                        action: { displaySettings.workspaceDetailLabVariant = variant }
                    )
                    .accessibilityIdentifier("MobileWorkspaceDetailLabVariant-\(variant.rawValue)")
                }
            } header: {
                Text(L10n.string(
                    "mobile.settings.workspaceDetailLab.redesignsSection",
                    defaultValue: "Five Redesigns"
                ))
            } footer: {
                Text(L10n.string(
                    "mobile.settings.workspaceDetailLab.footer",
                    defaultValue: "The selected design updates every open workspace detail immediately. No app restart is needed."
                ))
            }
        }
        .navigationTitle(L10n.string(
            "mobile.settings.workspaceDetailLab",
            defaultValue: "Workspace Detail Lab"
        ))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    WorkspaceDetailLabPreviewView()
                } label: {
                    Label(
                        L10n.string(
                            "mobile.settings.workspaceDetailLab.openPreview",
                            defaultValue: "Open Live Preview"
                        ),
                        systemImage: "play.rectangle"
                    )
                    .labelStyle(.iconOnly)
                }
                .accessibilityLabel(L10n.string(
                    "mobile.settings.workspaceDetailLab.openPreview",
                    defaultValue: "Open Live Preview"
                ))
                .accessibilityIdentifier("MobileWorkspaceDetailLabOpenPreview")
            }
        }
        .accessibilityIdentifier("MobileWorkspaceDetailLab")
    }

    private func title(for variant: WorkspaceDetailLabVariant) -> String {
        switch variant {
        case .titleSwitcher:
            L10n.string(
                "mobile.settings.workspaceDetailLab.titleSwitcher",
                defaultValue: "Title Switcher"
            )
        case .terminalFocus:
            L10n.string(
                "mobile.settings.workspaceDetailLab.terminalFocus",
                defaultValue: "Terminal Focus"
            )
        case .switcherSheet:
            L10n.string(
                "mobile.settings.workspaceDetailLab.switcherSheet",
                defaultValue: "Switcher Sheet"
            )
        case .inlineTabs:
            L10n.string(
                "mobile.settings.workspaceDetailLab.inlineTabs",
                defaultValue: "Inline Tabs"
            )
        case .titleStepper:
            L10n.string(
                "mobile.settings.workspaceDetailLab.titleStepper",
                defaultValue: "Title + Stepper"
            )
        }
    }

    private func detail(for variant: WorkspaceDetailLabVariant) -> String {
        switch variant {
        case .titleSwitcher:
            L10n.string(
                "mobile.settings.workspaceDetailLab.titleSwitcher.detail",
                defaultValue: "The complete feedback proposal: tap the title for terminals, with rename, read state, and close actions at the bottom."
            )
        case .terminalFocus:
            L10n.string(
                "mobile.settings.workspaceDetailLab.terminalFocus.detail",
                defaultValue: "The terminal name leads the header and opens a focused terminal list; tools move to an overflow menu."
            )
        case .switcherSheet:
            L10n.string(
                "mobile.settings.workspaceDetailLab.switcherSheet.detail",
                defaultValue: "The title opens a large bottom sheet with terminals, creation tools, and workspace actions."
            )
        case .inlineTabs:
            L10n.string(
                "mobile.settings.workspaceDetailLab.inlineTabs.detail",
                defaultValue: "An always-visible horizontal terminal strip sits below the toolbar for direct switching."
            )
        case .titleStepper:
            L10n.string(
                "mobile.settings.workspaceDetailLab.titleStepper.detail",
                defaultValue: "The title opens the full switcher while previous and next buttons cycle terminals in one tap."
            )
        }
    }
}
#endif
