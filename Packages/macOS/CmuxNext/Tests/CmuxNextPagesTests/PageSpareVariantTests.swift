@testable import CmuxNextPages
import Testing

/// `CMUX_NEXT_SETTINGS_SPARE` picks the parked Settings spare (cmux#48756). No value keeps the default, and an
/// unknown one also falls back to it (and is logged), so a typo never turns into a variant nobody asked for.
@Suite struct PageSpareVariantTests {
    @Test func noValueIsTheDefault() {
        #expect(PageSpareVariant.variant(nil) == .painted)
        #expect(PageSpareVariant.variant("") == .painted)
        #expect(PageSpareVariant.defaultVariant == .painted)
    }

    @Test func knownValuesInAnyCase() {
        #expect(PageSpareVariant.variant("unmounted") == .unmounted)
        #expect(PageSpareVariant.variant("Unmounted") == .unmounted)
        #expect(PageSpareVariant.variant("painted") == .painted)
    }

    @Test func droppedAndUnknownValuesFallBack() {
        #expect(PageSpareVariant.variant("hidden") == .painted)
        #expect(PageSpareVariant.variant("blank") == .painted)
        #expect(PageSpareVariant.variant("unmount") == .painted)
    }
}
