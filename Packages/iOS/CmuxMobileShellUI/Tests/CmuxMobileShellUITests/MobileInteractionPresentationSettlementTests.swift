import Testing
@testable import CmuxMobileShellUI

@Test func presentationSettlementWaitsForUIKitAfterModelCompletion() {
    var settlement = MobileInteractionPresentationSettlement()

    let settledAfterModel = settlement.mark(.model)
    #expect(!settledAfterModel)
    #expect(!settlement.presentationSettled)
    let settledAfterPresentation = settlement.mark(.presentation)
    #expect(settledAfterPresentation)
}

@Test func presentationSettlementWaitsForModelAfterUIKitAppearance() {
    var settlement = MobileInteractionPresentationSettlement()

    let settledAfterPresentation = settlement.mark(.presentation)
    #expect(!settledAfterPresentation)
    #expect(!settlement.modelSettled)
    let settledAfterModel = settlement.mark(.model)
    #expect(settledAfterModel)
}

@Test func duplicatePresentationMilestonesDoNotSettleEarly() {
    var settlement = MobileInteractionPresentationSettlement()

    let firstPresentation = settlement.mark(.presentation)
    let duplicatePresentation = settlement.mark(.presentation)
    let settledAfterModel = settlement.mark(.model)
    #expect(!firstPresentation)
    #expect(!duplicatePresentation)
    #expect(settledAfterModel)
}
