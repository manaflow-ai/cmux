import SwiftUI
import Testing

@testable import CmuxMobileShellUI

@Suite("Transactional child sheet presentation")
struct MobileChildSheetPresentationTransactionTests {
    @Test @MainActor
    func deniedPresentationDoesNotRunAcquiredSideEffects() {
        var sideEffectCount = 0
        let presentation = MobileChildSheetPresentation(
            isPresented: Binding(
                get: { false },
                set: { _ in }
            )
        )

        let didPresent = presentation.present {
            sideEffectCount += 1
        }

        #expect(!didPresent)
        #expect(sideEffectCount == 0)
    }

    @Test @MainActor
    func acceptedPresentationRunsSideEffectsAfterAcquisition() {
        var isPresented = false
        var events: [String] = []
        let presentation = MobileChildSheetPresentation(
            isPresented: Binding(
                get: { isPresented },
                set: { newValue in
                    isPresented = newValue
                    if newValue {
                        events.append("acquired")
                    }
                }
            )
        )

        let didPresent = presentation.present {
            events.append("side effect")
        }

        #expect(didPresent)
        #expect(events == ["acquired", "side effect"])
    }
}
