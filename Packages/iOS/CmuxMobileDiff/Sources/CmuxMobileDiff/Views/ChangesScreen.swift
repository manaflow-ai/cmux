public import CmuxMobileRPC
public import Foundation
public import SwiftUI

/// Embeddable, phone-first native workspace changes screen.
public struct ChangesScreen: View {
    @State private var model: ChangesViewModel
    @Environment(\.colorScheme) private var colorScheme
    private let scrollToPath: String?

    /// Creates a live native changes screen.
    /// - Parameters:
    ///   - service: Workspace-bound changes service.
    ///   - workspace: Workspace context for local preferences.
    ///   - baseSpec: Requested Git comparison base.
    ///   - scrollToPath: Optional file path to reveal after loading.
    ///   - defaults: Injected device-local defaults.
    public init(
        service: any MobileChangesLoading,
        workspace: ChangesWorkspaceContext,
        baseSpec: MobileChangesBaseSpec = MobileChangesBaseSpec(kind: .workingTree),
        scrollToPath: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        _model = State(initialValue: ChangesViewModel(
            service: service,
            workspace: workspace,
            baseSpec: baseSpec,
            defaults: defaults
        ))
        self.scrollToPath = scrollToPath
    }

    /// The live, continuously scrolling changed-files surface.
    public var body: some View {
        #if os(iOS)
        ChangesListView(snapshot: model.snapshot, actions: model.actions, scrollToPath: scrollToPath)
            .navigationTitle(String(localized: "diff.navigation.title", defaultValue: "Changes", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
            .onChange(of: colorScheme, initial: true) { _, scheme in
                model.setHighlightScheme(scheme == .dark ? .dark : .light)
            }
            .onDisappear { model.cancelTransientWork() }
        #else
        ChangesListView(snapshot: model.snapshot, actions: model.actions, scrollToPath: scrollToPath)
            .navigationTitle(String(localized: "diff.navigation.title", defaultValue: "Changes", bundle: .module))
            .task { await model.load() }
            .onChange(of: colorScheme, initial: true) { _, scheme in
                model.setHighlightScheme(scheme == .dark ? .dark : .light)
            }
            .onDisappear { model.cancelTransientWork() }
        #endif
    }
}
