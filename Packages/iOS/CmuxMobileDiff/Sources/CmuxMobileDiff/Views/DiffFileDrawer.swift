internal import SwiftUI

/// Pull-up file tree with collapsed, half-height, and full-height detents.
struct DiffFileDrawer: View {
    let snapshot: ChangesScreenSnapshot
    let actions: ChangesScreenActions
    let layoutPreference: DiffLayoutPreference
    let setLayoutPreference: @MainActor @Sendable (DiffLayoutPreference) -> Void
    let selectFile: @MainActor @Sendable (String) -> Void
    @Binding var detent: DiffDrawerDetent
    @GestureState private var dragTranslation: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy) {
                        detent = detent == .collapsed ? .half : .collapsed
                    }
                } label: {
                    Capsule()
                        .fill(.secondary)
                        .frame(width: 38, height: 5)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(
                    localized: "diff.drawer.files",
                    defaultValue: "Changed files",
                    bundle: .module
                ))

                ChangesFileTreeView(
                    snapshot: snapshot,
                    actions: actions,
                    layoutPreference: layoutPreference,
                    setLayoutPreference: setLayoutPreference,
                    selectFile: selectFile
                )
                .opacity(detent == .collapsed ? 0 : 1)
                .allowsHitTesting(detent != .collapsed)
            }
            .frame(height: drawerHeight(in: geometry.size.height), alignment: .top)
            .background(.regularMaterial)
            .clipShape(.rect(topLeadingRadius: 18, topTrailingRadius: 18))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, y: -3)
            .offset(y: max(0, dragTranslation))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .updating($dragTranslation) { value, state, _ in state = value.translation.height }
                    .onEnded { value in settle(after: value.predictedEndTranslation.height) }
            )
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func drawerHeight(in availableHeight: CGFloat) -> CGFloat {
        switch detent {
        case .collapsed: 48
        case .half: max(260, availableHeight * 0.52)
        case .full: max(320, availableHeight - 12)
        }
    }

    private func settle(after translation: CGFloat) {
        let next: DiffDrawerDetent
        if translation < -80 {
            next = switch detent {
            case .collapsed: .half
            case .half, .full: .full
            }
        } else if translation > 80 {
            next = switch detent {
            case .full: .half
            case .half, .collapsed: .collapsed
            }
        } else {
            next = detent
        }
        withAnimation(.snappy) { detent = next }
    }
}
