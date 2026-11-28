import SwiftUI
import Testing

@testable import CmuxMobileShellUI

@Suite("Child sheet presentation identity")
struct MobileChildSheetPresentationTests {
    @Test @MainActor
    func equalChildCasesKeepPresenterIdentityAndExclusiveOwnership() {
        let rootState = MobileRootPresentationStateBox()
        var firstIsPresented = false
        var secondIsPresented = false
        let child = MobileRootPresentationState.ChildPresentation.workspaceList(.customization)
        let provider = provider(rootState: rootState)
        let first = provider.presentation(
            for: child,
            fallback: Binding(
                get: { firstIsPresented },
                set: { firstIsPresented = $0 }
            )
        )
        let second = provider.presentation(
            for: child,
            fallback: Binding(
                get: { secondIsPresented },
                set: { secondIsPresented = $0 }
            )
        )

        #expect(first.present())
        #expect(firstIsPresented)
        #expect(first.isPresented.wrappedValue)

        #expect(!second.present())
        #expect(!secondIsPresented)
        #expect(!second.isPresented.wrappedValue)

        first.dismiss()
        #expect(!firstIsPresented)
        #expect(rootState.value.presentation == .dismissingChild(child, pendingPairing: nil))
        #expect(!second.present())
        #expect(!secondIsPresented)

        first.didDismiss()
        #expect(rootState.value.isIdle)
        #expect(second.present())
        #expect(secondIsPresented)
        #expect(second.isPresented.wrappedValue)
    }

    @Test @MainActor
    func rootForcedDismissalClearsOnlyTheActiveLocalIdentityOnDidDismiss() {
        let rootState = MobileRootPresentationStateBox()
        var localIsPresented = false
        let child = MobileRootPresentationState.ChildPresentation.workspaceDetail(.terminalArtifactFiles)
        let presentation = provider(rootState: rootState).presentation(
            for: child,
            fallback: Binding(
                get: { localIsPresented },
                set: { localIsPresented = $0 }
            )
        )

        #expect(presentation.present())
        #expect(localIsPresented)

        rootState.value.apply(.authenticationChanged(isAuthenticated: false))
        #expect(!presentation.isPresented.wrappedValue)
        #expect(localIsPresented)

        presentation.didDismiss()
        #expect(!localIsPresented)
        #expect(rootState.value.isIdle)
    }

    @MainActor
    private func provider(
        rootState: MobileRootPresentationStateBox
    ) -> MobileChildPresentationProvider {
        MobileChildPresentationProvider { child in
            MobileChildSheetPresentation(
                isPresented: Binding(
                    get: { rootState.value.isPresentingChild(child) },
                    set: { isPresented in
                        rootState.value.apply(
                            isPresented ? .presentChild(child) : .dismissChild(child)
                        )
                    }
                ),
                didDismiss: {
                    rootState.value.apply(.childDidDismiss(child))
                }
            )
        }
    }
}

@MainActor
private final class MobileRootPresentationStateBox {
    var value = MobileRootPresentationState()
}
