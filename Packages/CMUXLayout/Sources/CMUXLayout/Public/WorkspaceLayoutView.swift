import SwiftUI

/// Main entry point for the CMUXLayout library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = WorkspaceLayoutController()
///
///     var body: some View {
///         WorkspaceLayoutView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         } emptyPane: { paneId in
///             Text("Empty pane")
///         }
///     }
/// }
/// ```
public struct WorkspaceLayoutView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: WorkspaceLayoutController
    private let contentBuilder: (SurfaceTab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent

    /// Initialize with a controller, content builder, and empty pane builder
    /// - Parameters:
    ///   - controller: The WorkspaceLayoutController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    public init(
        controller: WorkspaceLayoutController,
        @ViewBuilder content: @escaping (SurfaceTab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    public var body: some View {
        SplitViewContainer(
            contentBuilder: { tabItem, paneId in
                contentBuilder(SurfaceTab(from: tabItem), PaneID(id: paneId.id))
            },
            emptyPaneBuilder: { internalPaneId in
                emptyPaneBuilder(PaneID(id: internalPaneId.id))
            },
            appearance: controller.configuration.appearance,
            showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
            contentViewLifecycle: controller.configuration.contentViewLifecycle,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            },
            enableAnimations: controller.configuration.appearance.enableAnimations,
            animationDuration: controller.configuration.appearance.animationDuration
        )
        .environment(controller)
        .environment(controller.internalController)
    }
}

// MARK: - Convenience initializer with default empty view

extension WorkspaceLayoutView where EmptyContent == DefaultEmptyPaneView {
    /// Initialize with a controller and content builder, using the default empty pane view
    /// - Parameters:
    ///   - controller: The WorkspaceLayoutController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    public init(
        controller: WorkspaceLayoutController,
        @ViewBuilder content: @escaping (SurfaceTab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultEmptyPaneView() }
    }
}

/// Default view shown when a pane has no tabs
public struct DefaultEmptyPaneView: View {
    public init() {}

    public var body: some View {
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
