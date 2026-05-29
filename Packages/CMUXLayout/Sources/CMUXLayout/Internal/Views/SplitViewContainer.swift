import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (SurfaceItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: WorkspaceLayoutConfiguration.Appearance
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TabBarColors.paneBackground(for: appearance))
                .focusable()
                .focusEffectDisabled()
                .onChange(of: frame) { _, newFrame in
                    updateContainerFrame(newFrame)
                }
                .onAppear {
                    updateContainerFrame(frame)
                }
        }
    }

    private func updateContainerFrame(_ frame: CGRect) {
        controller.setContainerFrame(frame)
        onGeometryChange?(false)
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        let nodeToRender = controller.zoomedNode ?? controller.rootNode
        SplitNodeView(
            node: nodeToRender,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            appearance: appearance,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange,
            enableAnimations: enableAnimations,
            animationDuration: animationDuration
        )
    }
}
