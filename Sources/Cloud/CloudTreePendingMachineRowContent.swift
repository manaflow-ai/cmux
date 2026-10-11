import CmuxCloud
import CmuxFoundation
import SwiftUI

/// A machine that does not exist yet (or failed to): the row the Machines
/// panel shows from the moment the sheet's Create is pressed until the fleet
/// list returns the real machine. Mirrors ``CloudTreeMachineRowContent``'s
/// two layouts so the row sits in the same column grid as its neighbours;
/// a spinner while running, or a warning once failed, follows the name.
struct CloudTreePendingMachineRowContent: View {
    let operation: MachineCreateOperation
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        if operation.failureOutput != nil {
            failureRow
                .accessibilityElement(children: .combine)
                .accessibilityLabel(operation.summaryLine)
        } else {
            pendingRow
        }
    }

    @ViewBuilder
    private var pendingRow: some View {
        switch style.machineRowLayout {
        case .singleLine:
            CloudTreeMachineBand(style: style) {
                // Centered, not baseline-aligned: the glyph has no text
                // baseline, so on a baseline it drops below the name.
                HStack(alignment: .center, spacing: style.rowGrid.dotGap) {
                    name
                    statusGlyph
                    status
                        .layoutPriority(1)
                    Spacer(minLength: style.rowGrid.trailingGap)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.summaryLine)
        case .twoLine:
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: scaled(style.rowGrid.machineLineSpacing)) {
                    HStack(alignment: .center, spacing: style.rowGrid.dotGap) {
                        name
                        statusGlyph
                    }
                    .frame(height: scaled(style.machineNameLineHeight))
                    status
                        .frame(height: scaled(style.machineSubtitleLineHeight))
                }
                Spacer(minLength: style.rowGrid.trailingGap)
            }
            .padding(.vertical, scaled(style.machineVerticalPadding))
            .padding(.trailing, style.rowGrid.trailingPadding)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(operation.summaryLine)
        }
    }

    /// A failed create has no machine identity to show. Rendering the request
    /// placeholder beside the failure duplicates the same row's meaning and
    /// leaves a truncated `New…` label before the useful error text.
    private var failureRow: some View {
        CloudTreeMachineBand(style: style) {
            HStack(alignment: .center, spacing: style.rowGrid.dotGap) {
                statusGlyph
                status
                    .layoutPriority(1)
                Spacer(minLength: style.rowGrid.trailingGap)
            }
            .frame(height: scaled(style.machineNameLineHeight))
        }
    }

    /// Progress or failure, drawn after the name rather than in a leading slot:
    /// the name sits on the column the created machine's row will use, so it
    /// does not jump when the fleet list returns the real machine.
    @ViewBuilder
    private var statusGlyph: some View {
        if operation.isRunning || operation.isReconciling {
            ProgressView()
                .controlSize(.mini)
        } else {
            CmuxSystemSymbolImage(
                magnified: "exclamationmark.triangle.fill",
                pointSize: style.iconSize,
                weight: .medium,
                tint: .orange
            )
        }
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }

    private var name: some View {
        Text(operation.request.displayName)
            .cmuxFont(size: style.machineNameSize, weight: style.machineBand ? .semibold : .medium, design: style.fontDesign)
            .foregroundStyle(operation.isRunning || operation.isReconciling ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var status: some View {
        Text(operation.statusLabel)
            .cmuxFont(size: style.detailSize, design: style.fontDesign)
            .foregroundStyle(operation.isRunning || operation.isReconciling ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange.opacity(0.9)))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
