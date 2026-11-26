import CmuxMobileShell
import Testing

@Suite
struct MobileMacAppVersionTests {
    @Test(arguments: [
        ("0", [0]),
        ("0.64", [0, 64]),
        ("0.64.16", [0, 64, 16]),
    ])
    func parsesValidVersions(input: String, expectedComponents: [Int]) throws {
        let version = try #require(MobileMacAppVersion(parsing: input))
        #expect(version.components == expectedComponents)
        #expect(version.description == expectedComponents.map(String.init).joined(separator: "."))
    }

    @Test(arguments: [
        "",
        "0.65.0-nightly",
        "abc",
        "1..2",
        "1.2.3.4",
        "-1",
        "1.-2",
        " 1.2",
        "1.2 ",
        "1 .2",
    ])
    func rejectsInvalidVersions(input: String) {
        #expect(MobileMacAppVersion(parsing: input) == nil)
    }

    @Test
    func comparesVersionsNumericallyWithMissingTrailingZeroes() throws {
        let version06415 = try #require(MobileMacAppVersion(parsing: "0.64.15"))
        let version06416 = try #require(MobileMacAppVersion(parsing: "0.64.16"))
        let version065 = try #require(MobileMacAppVersion(parsing: "0.65"))
        let version0650 = try #require(MobileMacAppVersion(parsing: "0.65.0"))
        let version10 = try #require(MobileMacAppVersion(parsing: "1.0"))

        #expect(version06415 < version06416)
        #expect(version06416 < version065)
        #expect(version065 == version0650)
        #expect(version065 < version10)
    }
}
