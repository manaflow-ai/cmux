import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceSurfaceOverviewSheet: View {
    let value: WorkspaceSurfaceDeckValue
    let terminalTheme: TerminalTheme
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let createTerminal: (MobileWorkspacePanePreview.ID?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    spatialMap
                        .frame(height: 250)

                    ForEach(value.panes) { pane in
                        paneSection(pane)
                    }
                }
                .padding(16)
            }
            .background(terminalTheme.terminalBackgroundColor)
            .navigationTitle(L10n.string("mobile.surfaceDeck.overview", defaultValue: "Pane Overview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
            }
        }
        .mobileTerminalNavigationChrome(theme: terminalTheme)
        .environment(\.colorScheme, terminalTheme.terminalColorScheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobilePaneOverviewSheet")
    }

    private var spatialMap: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(chromeForeground.opacity(0.045))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(chromeForeground.opacity(0.12), lineWidth: 0.5)
                    }

                ForEach(value.panes) { pane in
                    spatialPane(pane)
                        .frame(
                            width: max(1, size.width * pane.frame.width - 6),
                            height: max(1, size.height * pane.frame.height - 6)
                        )
                        .position(
                            x: size.width * (pane.frame.x + pane.frame.width / 2),
                            y: size.height * (pane.frame.y + pane.frame.height / 2)
                        )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("mobile.surfaceDeck.spatialMap", defaultValue: "Workspace pane layout"))
    }

    private func spatialPane(_ pane: WorkspaceSurfaceDeckValue.Pane) -> some View {
        let isActive = pane.id == value.activePaneID
        return Button {
            guard let terminalID = pane.selectedTerminal?.id else { return }
            selectAndDismiss(terminalID)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(L10n.paneName(index: pane.index))
                        .font(.caption2.weight(.bold))
                    Spacer(minLength: 0)
                    Text("\(pane.terminals.count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(chromeForeground.opacity(0.1), in: Capsule())
                }
                Text(
                    pane.selectedTerminal?.name
                        ?? L10n.string("mobile.surfaceDeck.emptyPane", defaultValue: "No Terminal")
                )
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach(Array(pane.terminals.prefix(4).enumerated()), id: \.element.id) { index, terminal in
                        Capsule()
                            .fill(
                                terminal.id == value.selectedTerminalID
                                    ? Color.accentColor
                                    : chromeForeground.opacity(0.28)
                            )
                            .frame(width: index == 0 ? 26 : 16, height: 3)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(isActive ? Color.accentColor : chromeForeground)
            .background(
                isActive ? Color.accentColor.opacity(0.16) : chromeForeground.opacity(0.065),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.78) : chromeForeground.opacity(0.14),
                        lineWidth: isActive ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(pane.selectedTerminal == nil)
        .accessibilityIdentifier("MobilePaneMapItem-\(pane.id.rawValue)")
    }

    private func paneSection(_ pane: WorkspaceSurfaceDeckValue.Pane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.paneName(index: pane.index))
                    .font(.headline)
                Text(L10n.surfaceTabCount(pane.terminals.count))
                    .font(.caption)
                    .foregroundStyle(dimChromeForeground)
                Spacer()
                Button {
                    createTerminal(pane.remoteID)
                    dismiss()
                } label: {
                    Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("MobilePaneOverviewNewTerminal-\(pane.id.rawValue)")
            }

            if pane.terminals.isEmpty {
                Text(L10n.string("mobile.surfaceDeck.emptyPane", defaultValue: "No Terminal"))
                    .font(.subheadline)
                    .foregroundStyle(dimChromeForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ForEach(pane.terminals) { terminal in
                    Button {
                        selectAndDismiss(terminal.id)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "terminal")
                                .frame(width: 20)
                            Text(terminal.name)
                                .lineLimit(1)
                            Spacer()
                            if terminal.id == value.selectedTerminalID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(chromeForeground)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(chromeForeground.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("MobilePaneOverviewTab-\(terminal.id.rawValue)")
                }
            }
        }
        .padding(13)
        .background(chromeForeground.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(chromeForeground.opacity(0.1), lineWidth: 0.5)
        }
    }

    private func selectAndDismiss(_ terminalID: MobileTerminalPreview.ID) {
        selectTerminal(terminalID)
        dismiss()
    }

    private var chromeForeground: Color {
        terminalTheme.terminalChromeForegroundColor
    }

    private var dimChromeForeground: Color {
        chromeForeground.opacity(0.78)
    }
}
