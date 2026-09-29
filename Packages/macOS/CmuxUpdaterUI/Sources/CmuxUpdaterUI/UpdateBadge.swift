public import SwiftUI
public import CmuxAppKitSupportUI
public import CmuxUpdater
import AppKit

/// A badge view that displays the current state of an update operation (icon, progress ring,
/// or loading spinner) for the update pill.
public struct UpdateBadge: View {
    private let model: UpdateStateModel
    private let appearance: UpdateAppearance

    private static let iconSize: CGFloat = 14
    private static let iconPointSize: CGFloat = 13
    private static let iconWeight: NSFont.Weight = .semibold

    /// Creates a badge for `model`, using `appearance` for the loading-spinner tint.
    public init(model: UpdateStateModel, appearance: UpdateAppearance) {
        self.model = model
        self.appearance = appearance
    }

    public var body: some View {
        badgeContent
            .accessibilityLabel(model.text)
    }

    @ViewBuilder
    private var badgeContent: some View {
        if model.showsDetectedBackgroundUpdate {
            if let iconName = model.iconName {
                badgeImage(iconName)
            }
        } else {
            switch model.effectiveState {
            case .downloading(let download):
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = min(1, max(0, Double(download.progress) / Double(expectedLength)))
                    ProgressRingView(progress: progress)
                } else {
                    badgeImage("arrow.down.circle")
                }

            case .extracting(let extracting):
                ProgressRingView(progress: min(1, max(0, extracting.progress)))

            case .preparingCheck, .checking, .startingDownload:
                BrowserStyleLoadingSpinner(size: 14, color: appearance.foregroundColor(for: model))

            default:
                if let iconName = model.iconName {
                    badgeImage(iconName)
                }
            }
        }
    }

    /// Builds the AppKit-owned request used by every updater symbol.
    @MainActor
    static func hostedIconRequest(
        systemName: String,
        tintColor: NSColor
    ) -> CmuxResolvedIconRequest {
        CmuxResolvedIconRequest(
            source: .systemSymbol(name: systemName, accessibilityDescription: nil),
            size: NSSize(width: iconSize, height: iconSize),
            tintColor: tintColor,
            symbolWeight: iconWeight,
            symbolPointSize: iconPointSize
        )
    }

    private func badgeImage(_ systemName: String) -> some View {
        CmuxResolvedIconImage(request: Self.hostedIconRequest(
            systemName: systemName,
            tintColor: NSColor(appearance.foregroundColor(for: model))
        ))
        .frame(width: Self.iconSize, height: Self.iconSize)
        .accessibilityHidden(true)
    }
}

private struct ProgressRingView: View {
    let progress: Double
    let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.2), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }
}

private struct BrowserStyleLoadingSpinner: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0

            ZStack {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        }
    }

    private var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }
}
