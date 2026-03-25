import SwiftUI

// MARK: - Main View

struct PaperLayoutView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: PaperLayoutController
    private let contentBuilder: (PaperTab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent

    init(
        controller: PaperLayoutController,
        @ViewBuilder content: @escaping (PaperTab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width
            let viewportHeight = geometry.size.height

            HStack(spacing: 0) {
                ForEach(controller.panes) { pane in
                    let resolvedWidth = (pane.width <= 0 || pane.width == .infinity)
                        ? viewportWidth
                        : pane.width
                    PaperPaneContainerView(
                        pane: pane,
                        controller: controller,
                        contentBuilder: contentBuilder,
                        emptyPaneBuilder: emptyPaneBuilder
                    )
                    .frame(width: resolvedWidth, height: viewportHeight)
                }
            }
            .offset(x: -controller.viewportOffset)
            // No SwiftUI .animation() here. Viewport animation is driven
            // manually via CVDisplayLink so that viewportOffset matches the
            // visual position on every frame, keeping portal positions in sync.
            .clipped()
            .onAppear {
                controller.viewportWidth = viewportWidth
                controller.viewportHeight = viewportHeight
                resolveInitialPaneWidths()
            }
            .onChange(of: geometry.size) { _, newSize in
                let oldWidth = controller.viewportWidth
                controller.viewportWidth = newSize.width
                controller.viewportHeight = newSize.height

                if oldWidth > 0 && !controller.panes.isEmpty {
                    let scale = newSize.width / oldWidth
                    for pane in controller.panes {
                        pane.width = max(
                            pane.width * scale,
                            controller.configuration.appearance.minimumPaneWidth
                        )
                    }
                }
            }
        }
    }

    /// Resolve panes that used a placeholder width (e.g., fullscreen initial pane).
    private func resolveInitialPaneWidths() {
        guard controller.viewportWidth > 0 else { return }
        // If there's exactly one pane, it should fill the viewport
        if controller.panes.count == 1 {
            controller.panes[0].width = controller.viewportWidth
        } else {
            for pane in controller.panes {
                if !pane.width.isFinite || pane.width <= 0 {
                    pane.width = controller.viewportWidth
                }
            }
        }
        controller.notifyGeometryChange()
    }
}

// MARK: - Convenience initializer (default empty view)

extension PaperLayoutView where EmptyContent == DefaultPaperEmptyPaneView {
    init(
        controller: PaperLayoutController,
        @ViewBuilder content: @escaping (PaperTab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultPaperEmptyPaneView() }
    }
}

struct DefaultPaperEmptyPaneView: View {
    init() {}
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pane Container

private struct PaperPaneContainerView<Content: View, EmptyContent: View>: View {
    let pane: PaperPane
    let controller: PaperLayoutController
    let contentBuilder: (PaperTab, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent

    private var isFocused: Bool {
        controller.focusedPaneId == pane.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            if controller.panes.count > 1 || pane.tabs.count > 1 {
                PaperTabBarView(
                    pane: pane,
                    controller: controller,
                    isFocused: isFocused
                )
            }

            // Content area
            ZStack {
                if pane.tabs.isEmpty {
                    emptyPaneBuilder(pane.id)
                } else if controller.configuration.contentViewLifecycle == .keepAllAlive {
                    ForEach(pane.tabs, id: \.id) { tabItem in
                        let tab = PaperTab(from: tabItem)
                        let isSelected = tabItem.id == pane.selectedTabId
                        contentBuilder(tab, pane.id)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                    }
                } else {
                    if let selectedItem = pane.selectedTab {
                        let tab = PaperTab(from: selectedItem)
                        contentBuilder(tab, pane.id)
                    }
                }
            }
        }
        .overlay(alignment: .trailing) {
            // Resize handle + separator on the right edge (except for the last pane)
            if let paneIndex = controller.paneIndex(pane.id),
               paneIndex < controller.panes.count - 1 {
                PaperResizeHandle(
                    controller: controller,
                    leftPaneIndex: paneIndex
                )
            }
        }
    }
}

// MARK: - Resize Handle

private struct PaperResizeHandle: View {
    let controller: PaperLayoutController
    let leftPaneIndex: Int

    @State private var isDragging = false
    @State private var dragStartWidths: (left: CGFloat, right: CGFloat) = (0, 0)

    private let handleWidth: CGFloat = 6

    var body: some View {
        ZStack {
            // Visible 1px separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            // Wider invisible hit area
            Rectangle()
                .fill(Color.clear)
                .frame(width: handleWidth)
                .contentShape(Rectangle())
        }
        .frame(width: handleWidth)
        .cursor(.resizeLeftRight)
        .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            let leftPane = controller.panes[leftPaneIndex]
                            let rightPane = controller.panes[leftPaneIndex + 1]
                            dragStartWidths = (leftPane.width, rightPane.width)
                        }

                        let delta = value.translation.width
                        let minWidth = controller.configuration.appearance.minimumPaneWidth

                        let newLeftWidth = max(minWidth, dragStartWidths.left + delta)
                        let newRightWidth = max(minWidth, dragStartWidths.right - delta)

                        // Only apply if both panes stay above minimum
                        if newLeftWidth >= minWidth && newRightWidth >= minWidth {
                            controller.panes[leftPaneIndex].width = newLeftWidth
                            controller.panes[leftPaneIndex + 1].width = newRightWidth
                        }

                        controller.notifyGeometryChange(isDragging: true)
                    }
                    .onEnded { _ in
                        isDragging = false
                        controller.notifyGeometryChange()
                    }
            )
    }
}

// MARK: - Cursor Extension

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
