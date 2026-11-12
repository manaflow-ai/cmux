import CmuxFoundation
import Testing

struct RemoteClientDeviceNameTests {
    @Test(arguments: [
        ("MacBook.local", "cmux-MacBook"),
        ("Austin's MacBook.local", "cmux-Austin-s-MacBook"),
        ("build-box.example.com", "cmux-build-box"),
        ("", "cmux-mac"),
        (String(repeating: "x", count: 100), "cmux-" + String(repeating: "x", count: 40))
    ])
    func keepsTheExistingRemoteLabelFormat(hostName: String, expected: String) {
        #expect(RemoteClientDeviceName(hostName: hostName).value == expected)
    }
}
