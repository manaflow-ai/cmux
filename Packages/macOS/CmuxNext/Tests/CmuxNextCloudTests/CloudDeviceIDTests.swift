@testable import CmuxNextCloud
import Foundation
import Testing

/// The device id is this installation's stable id (Cloud enrollment, and the `install:<id>` host
/// of agent chat tabs). It is read before any Cloud sign-in, so its directory may not exist yet.
@Suite struct CloudDeviceIDTests {
    @Test func aFreshInstallationGetsAStableDeviceID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = CloudPaths(root: root)
        let first = try paths.loadOrCreateDeviceID()
        #expect(first.hasPrefix("mac-"))
        #expect(try paths.loadOrCreateDeviceID() == first, "read back, not created again")
    }
}
