import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Rounded-rect kind glyph shared by surface headers, cards, and rows.
struct MacSurfaceIconBadge: View {
    let kind: MobileSurfacePreview.Kind
    var side: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
            .fill(kind.tint.opacity(0.16))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: kind.systemImage)
                    .font(.system(size: side * 0.46, weight: .medium))
                    .foregroundStyle(kind.tint)
            }
            .accessibilityHidden(true)
    }
}

/// Compact chrome row above a native Mac-surface renderer.
///
/// Keeps every surface's top edge consistent: kind badge, surface title,
/// contextual subtitle, an optional surface-specific accessory, and the
/// open-on-Mac affordance.
struct MacSurfaceHeader<Accessory: View>: View {
    let kind: MobileSurfacePreview.Kind
    let title: String
    let subtitle: String?
    let canOpenOnMac: Bool
    let openOnMac: () async -> Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            MacSurfaceIconBadge(kind: kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            accessory
            MacSurfaceOpenOnMacButton(isEnabled: canOpenOnMac, openOnMac: openOnMac)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

extension MacSurfaceHeader where Accessory == EmptyView {
    init(
        kind: MobileSurfacePreview.Kind,
        title: String,
        subtitle: String?,
        canOpenOnMac: Bool,
        openOnMac: @escaping () async -> Bool
    ) {
        self.init(
            kind: kind,
            title: title,
            subtitle: subtitle,
            canOpenOnMac: canOpenOnMac,
            openOnMac: openOnMac
        ) { EmptyView() }
    }
}

/// Icon-only open-on-Mac control with inline busy and failure feedback.
struct MacSurfaceOpenOnMacButton: View {
    let isEnabled: Bool
    let openOnMac: () async -> Bool
    /// Injected for tests; drives the bounded failure-glyph dwell.
    var clock: ContinuousClock = ContinuousClock()

    @State private var isFocusing = false
    @State private var showsFailure = false
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        Button {
            focusTask?.cancel()
            focusTask = Task { await runFocus() }
        } label: {
            ZStack {
                if isFocusing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: showsFailure ? "exclamationmark.triangle" : "macwindow.badge.plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(showsFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isFocusing)
        .accessibilityLabel(L10n.string("mobile.surface.openOnMac", defaultValue: "Open on Mac"))
        .onDisappear { focusTask?.cancel() }
    }

    @MainActor
    private func runFocus() async {
        isFocusing = true
        showsFailure = false
        let succeeded = await openOnMac()
        guard !Task.isCancelled else { return }
        isFocusing = false
        guard !succeeded else { return }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
        withAnimation(.snappy) { showsFailure = true }
        try? await clock.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) { showsFailure = false }
    }
}

/// Centered inline state (loading complement, error, empty) for surfaces.
struct MacSurfaceMessageView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    Label(
                        L10n.string("mobile.surface.retry", defaultValue: "Retry"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
