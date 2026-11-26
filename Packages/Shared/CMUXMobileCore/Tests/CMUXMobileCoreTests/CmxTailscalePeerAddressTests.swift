import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxTailscalePeerAddressTests {
    @Test func acceptsCanonicalTailscalePeerIPv4() {
        #expect(CmxTailscalePeerAddress("100.64.1.2")?.value == "100.64.1.2")
    }

    @Test func rejectsLeadingZeroIPv4Spellings() {
        // inet_pton accepts leading-zero octets as decimal on some Darwin versions,
        // while the dialer reads them as octal. A peer classifier must refuse the
        // non-canonical spelling so it never diverges from what actually gets dialed.
        #expect(CmxTailscalePeerAddress("0100.64.1.2") == nil)
        #expect(CmxTailscalePeerAddress("100.064.1.2") == nil)
    }
}
