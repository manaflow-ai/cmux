import SwiftUI

/// A badge view that displays the current state of an update operation.
struct UpdateBadge: View {
    @ObservedObject var model: UpdateViewModel
    @State private var rotationAngle: Double = 0

    var body: some View {
        badgeContent
            .accessibilityLabel(model.text)
    }

    @ViewBuilder
    private var badgeContent: some View {
        switch model.state {
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = min(1, max(0, Double(download.progress) / Double(expectedLength)))
                ProgressRingView(progress: progress)
            } else {
                Image(systemName: "arrow.down.circle")
            }

        case .extracting(let extracting):
            ProgressRingView(progress: min(1, max(0, extracting.progress)))

        case .checking:
            if let iconName = model.iconName {
                Image(systemName: iconName)
                    .rotationEffect(.degrees(rotationAngle))
                    .onAppear {
                        withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                            rotationAngle = 360
                        }
                    }
                    .onDisappear {
                        rotationAngle = 0
                    }
            }

        default:
            if let iconName = model.iconName {
                Image(systemName: iconName)
            }
        }
    }
}

fileprivate struct ProgressRingView: View {
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
