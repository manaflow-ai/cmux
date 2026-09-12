import Testing
@testable import CmuxFoundation

@Suite("Network address policy")
struct NetworkAddressPolicyTests {
    private let policy = NetworkAddressPolicy()

    @Test(
        "Local and reserved IPv4 ranges are rejected",
        arguments: [
            [0, 0, 0, 0],
            [10, 0, 0, 1],
            [100, 64, 0, 1],
            [127, 0, 0, 1],
            [169, 254, 1, 1],
            [172, 16, 0, 1],
            [192, 0, 2, 1],
            [192, 168, 0, 1],
            [198, 18, 0, 1],
            [198, 51, 100, 1],
            [203, 0, 113, 1],
            [224, 0, 0, 1],
        ]
    )
    func rejectsNonPublicIPv4(_ bytes: [UInt8]) {
        #expect(!policy.allowsPublicIPv4Address(bytes))
    }

    @Test(
        "Public IPv4 ranges are allowed",
        arguments: [
            [1, 1, 1, 1],
            [8, 8, 8, 8],
            [93, 184, 216, 34],
        ]
    )
    func allowsPublicIPv4(_ bytes: [UInt8]) {
        #expect(policy.allowsPublicIPv4Address(bytes))
    }

    @Test("Local host spellings and legacy loopback literals are rejected")
    func rejectsLocalHostSpellings() {
        #expect(!policy.allowsPublicInternetHost("localhost"))
        #expect(!policy.allowsPublicInternetHost("service.local"))
        #expect(!policy.allowsPublicInternetHost("127.1"))
        #expect(!policy.allowsPublicInternetHost("2130706433"))
        #expect(!policy.allowsPublicInternetHost("[::1]"))
        #expect(policy.allowsPublicInternetHost("example.com."))
    }

    @Test("IPv4-mapped private IPv6 is rejected")
    func rejectsMappedPrivateIPv6() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[10] = 0xFF
        bytes[11] = 0xFF
        bytes[12] = 127
        bytes[15] = 1
        #expect(!policy.allowsPublicIPv6Address(bytes))
    }
}
