#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminalKit
import CmuxTerminalSizing
import SwiftUI

/// Shared-sizing chrome over one terminal surface: the corner chip, the
/// "+N cols" pill, the reconnecting capsule, and the detached card. The
/// border, hatch and cut-edge fade are drawn by the surface itself (see
/// `GhosttySurfaceView+SharedSizing`) because they follow the letterbox rect.
struct TerminalSharedSizingOverlay: View {
    let store: CMUXMobileShellStore
    let surfaceID: String
    let tabTitle: String
    let topInset: CGFloat

    @State private var isSizeSheetPresented = false
    @State private var reattachInFlight = false
    @State private var reattachFailed = false

    private var deviceKind: TerminalDeviceKind {
        MobileTerminalDeviceIdentity.current().kind
    }

    var body: some View {
        let sizing = store.terminalSizing(for: surfaceID)
        let presentation = store.terminalSizingPresentation(for: surfaceID)
        ZStack {
            if case let .detached(reason, at)? = sizing?.attachment {
                detachedCard(reason: reason, at: at)
            } else {
                if sizing?.attachment == .reconnecting {
                    reconnectingCapsule
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, topInset + 10)
                }
                if let presentation {
                    boundsChrome(presentation)
                }
            }
        }
        .sheet(isPresented: $isSizeSheetPresented) {
            TerminalSizeSheet(store: store, surfaceID: surfaceID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Bounds chrome

    @ViewBuilder
    private func boundsChrome(_ presentation: MobileTerminalSizingPresentation) -> some View {
        let tint = Color(presentation.ownerColor)
        if presentation.showsChip {
            Button {
                isSizeSheetPresented = true
            } label: {
                Label {
                    Text(TerminalSizingText.chip(presentation))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: presentation.viewportDiffers
                        ? "rectangle.dashed"
                        : "rectangle.inset.filled")
                }
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(tint, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityHint(TerminalSizingText.chipAccessibilityHint())
            .accessibilityIdentifier("MobileTerminalSizingChip")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, topInset + 10)
            .padding(.leading, 10)
        }
        if let pill = cutPillText(presentation) {
            Text(pill)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(red: 0.96, green: 0.65, blue: 0.14), in: Capsule())
                .accessibilityLabel(TerminalSizingText.cutAccessibilityLabel(pill))
                .accessibilityIdentifier("MobileTerminalSizingCutPill")
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }
    }

    private func cutPillText(_ presentation: MobileTerminalSizingPresentation) -> String? {
        var parts: [String] = []
        if presentation.hiddenColumns > 0 {
            parts.append(TerminalSizingText.hiddenColumns(presentation.hiddenColumns))
        }
        if presentation.hiddenRows > 0 {
            parts.append(TerminalSizingText.hiddenRows(presentation.hiddenRows))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { TerminalSizingText.joined($0, $1) }
    }

    private var reconnectingCapsule: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(TerminalSizingText.reconnecting())
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileTerminalSizingReconnecting")
        .allowsHitTesting(false)
    }

    // MARK: Detached card

    private func detachedCard(reason: TerminalDetachReason, at: Date?) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(TerminalSizingText.detachedTitle(tab: tabTitle))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(TerminalSizingText.detachedMessage(reason: reason, at: at, deviceKind: deviceKind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if reattachFailed {
                    Text(TerminalSizingText.reattachFailed())
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 8) {
                    Button {
                        reattach(asViewer: false)
                    } label: {
                        Text(TerminalSizingText.reattach())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("MobileTerminalDetachedReattach")
                    Button {
                        reattach(asViewer: true)
                    } label: {
                        Text(TerminalSizingText.reattachAsViewer())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("MobileTerminalDetachedReattachAsViewer")
                }
                .controlSize(.large)
                .disabled(reattachInFlight)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
        .accessibilityIdentifier("MobileTerminalDetachedCard")
    }

    private func reattach(asViewer: Bool) {
        reattachInFlight = true
        reattachFailed = false
        Task { @MainActor in
            let succeeded = await store.reattachTerminal(surfaceID: surfaceID, asViewer: asViewer)
            reattachInFlight = false
            reattachFailed = !succeeded
        }
    }
}

extension Color {
    /// The SwiftUI color for a participant's owner color.
    init(_ participantColor: MobileTerminalSizingParticipantColor) {
        let rgb = participantColor.rgb
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension MobileTerminalSizingPresentation {
    /// The surface decoration, or `nil` when the viewport matches the grid.
    var boundsDecoration: TerminalSizingBoundsDecoration? {
        guard viewportDiffers, let viewer else { return nil }
        let rgb = ownerColor.rgb
        return TerminalSizingBoundsDecoration(
            gridColumns: grid.cols,
            gridRows: grid.rows,
            viewerColumns: viewer.cols,
            viewerRows: viewer.rows,
            ownerRed: rgb.red,
            ownerGreen: rgb.green,
            ownerBlue: rgb.blue
        )
    }
}
#endif
