#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import CmuxTerminalSizing
import SwiftUI

/// Shared-sizing chrome over one terminal surface: the reconnecting capsule,
/// the detached card, and the size sheet. The border, hatch, cut-edge fade
/// and size chip are drawn by the surface itself (see
/// `GhosttySurfaceView+SharedSizing`) because they follow the letterbox rect;
/// the chip's tap sets `isSizeSheetPresented`.
struct TerminalSharedSizingOverlay: View {
    let store: CMUXMobileShellStore
    let surfaceID: String
    let topInset: CGFloat
    @Binding var isSizeSheetPresented: Bool

    @State private var reattachInFlight = false
    @State private var reattachFailed = false

    private var deviceKind: TerminalDeviceKind {
        MobileTerminalDeviceIdentity.current().kind
    }

    var body: some View {
        let sizing = store.terminalSizing(for: surfaceID)
        ZStack {
            if case let .detached(reason, at)? = sizing?.attachment {
                detachedCard(reason: reason, at: at)
            } else if sizing?.attachment == .reconnecting {
                reconnectingCapsule
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, topInset + 10)
            }
        }
        .sheet(isPresented: $isSizeSheetPresented) {
            TerminalSizeSheet(store: store, surfaceID: surfaceID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var reconnectingCapsule: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(TerminalSizingText.reconnecting())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
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
            VStack(spacing: 8) {
                Text(TerminalSizingText.detachedTitle())
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
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
                VStack(spacing: 4) {
                    Button {
                        reattach(asViewer: false)
                    } label: {
                        Text(TerminalSizingText.reattach())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("MobileTerminalDetachedReattach")
                    Button(TerminalSizingText.reattachAsViewer()) {
                        reattach(asViewer: true)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.large)
                    .accessibilityIdentifier("MobileTerminalDetachedReattachAsViewer")
                }
                .disabled(reattachInFlight)
                .padding(.top, 12)
            }
            .padding(24)
            .frame(maxWidth: 360)
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

extension MobileTerminalSizingPresentation {
    /// The surface decoration whenever the host published a size state and
    /// this phone's viewport is known. The surface draws it only for a
    /// settled mismatch (`TerminalSizingChromeGate`).
    var boundsDecoration: TerminalSizingBoundsDecoration? {
        guard let viewer else { return nil }
        return TerminalSizingBoundsDecoration(
            gridColumns: grid.cols,
            gridRows: grid.rows,
            viewerColumns: viewer.cols,
            viewerRows: viewer.rows,
            viewportConfirmed: viewportConfirmed
        )
    }

    /// The size chip's copy, or `nil` when the chip does not show.
    var chipContent: TerminalSizingChipContent? {
        guard showsChip else { return nil }
        return TerminalSizingChipContent(
            title: TerminalSizingText.chip(self),
            compactTitle: TerminalSizingText.chipCompact(self),
            accessibilityLabel: TerminalSizingText.chipAccessibilityLabel(self),
            accessibilityHint: TerminalSizingText.chipAccessibilityHint()
        )
    }
}
#endif
