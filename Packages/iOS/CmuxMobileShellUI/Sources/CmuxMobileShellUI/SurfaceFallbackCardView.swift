import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Card for a surface that remains rendered by the paired Mac.
///
/// Kind-specific glyph and copy plus the one action that always works:
/// raising the surface in cmux on the Mac.
struct SurfaceFallbackCardView: View {
    let surface: MobileSurfacePreview
    let workspaceName: String
    let canOpenOnMac: Bool
    let openOnMac: () async -> Bool

    @State private var isFocusing = false
    @State private var focusFailed = false
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(surface.kind.tint.opacity(0.14))
                    .frame(width: 88, height: 88)
                Circle()
                    .stroke(surface.kind.tint.opacity(0.22), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: surface.kind.systemImage)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(surface.kind.tint)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 20)

            Text(surface.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .padding(.bottom, 4)

            Text(contextLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.bottom, 14)

            Text(surface.kind.fallbackExplainer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 36)
                .padding(.bottom, 24)

            Button {
                focusTask?.cancel()
                focusTask = Task { await runFocus() }
            } label: {
                HStack(spacing: 8) {
                    if isFocusing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "macwindow.badge.plus")
                    }
                    Text(L10n.string("mobile.surface.openOnMac", defaultValue: "Open on Mac"))
                }
                .font(.body.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canOpenOnMac || isFocusing)

            ZStack {
                // Reserved line so the failure message never reflows the card.
                Text(verbatim: " ").font(.footnote)
                if focusFailed {
                    Label(
                        L10n.string(
                            "mobile.surface.openOnMacFailed",
                            defaultValue: "Couldn't reach your Mac. Try again."
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 12)

            Spacer(minLength: 24)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { focusTask?.cancel() }
    }

    /// "Kind · In “Workspace”" so the card names where the surface lives.
    private var contextLine: String {
        let kindName = surface.kind.displayName
        let trimmedWorkspace = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWorkspace.isEmpty else { return kindName }
        let format = L10n.string(
            "mobile.surface.workspaceContextFormat",
            defaultValue: "%1$@ · In “%2$@”"
        )
        return String.localizedStringWithFormat(format, kindName, trimmedWorkspace)
    }

    @MainActor
    private func runFocus() async {
        isFocusing = true
        withAnimation(.snappy) { focusFailed = false }
        let succeeded = await openOnMac()
        guard !Task.isCancelled else { return }
        isFocusing = false
        guard !succeeded else { return }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
        withAnimation(.snappy) { focusFailed = true }
    }
}
