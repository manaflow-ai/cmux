import Foundation
import Testing
@testable import CmuxProjectIdentity

@Test
func projectIdentityIsEquatable() {
    let a = ProjectIdentity(projectName: "cmux", iconPNGData: nil, dominantColorHex: "#FF0000", monogram: "CM")
    let b = ProjectIdentity(projectName: "cmux", iconPNGData: nil, dominantColorHex: "#FF0000", monogram: "CM")
    #expect(a == b)
}
