import Foundation
import Testing
@testable import CmuxNextAgentList

@Test("the wrapper requires the ABI-3 header")
func abiVersionIsPinned() {
    #expect(AcpmuxClient.expectedABIVersion == 3)
}

@Test("the byte driver cap is one MiB")
func byteDriverCap() {
    #expect(AcpmuxClientByteConnection.maxUndeliveredBytes == 1 << 20)
}
