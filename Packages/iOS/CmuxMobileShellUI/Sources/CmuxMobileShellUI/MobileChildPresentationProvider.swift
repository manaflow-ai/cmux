import SwiftUI

/// Resolves descendant presentation handles against the root modal state.
struct MobileChildPresentationProvider {
    private let resolve: (
        MobileRootPresentationState.ChildPresentation
    ) -> MobileChildSheetPresentation

    /// Creates a provider backed by the root presentation coordinator.
    init(
        resolve: @escaping (
            MobileRootPresentationState.ChildPresentation
        ) -> MobileChildSheetPresentation
    ) {
        self.resolve = resolve
    }

    /// Returns one presenter's local identity coordinated with the root modal grant.
    func presentation(
        for child: MobileRootPresentationState.ChildPresentation,
        fallback: Binding<Bool>
    ) -> MobileChildSheetPresentation {
        resolve(child).coordinated(with: fallback)
    }
}

extension EnvironmentValues {
    /// The root modal coordinator, absent in previews and standalone hosts.
    @Entry var mobileChildPresentationProvider: MobileChildPresentationProvider? = nil
}
