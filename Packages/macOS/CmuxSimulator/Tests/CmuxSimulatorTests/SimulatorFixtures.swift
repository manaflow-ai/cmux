import Foundation

/// Shared `simctl list devices --json` fixtures.
enum SimulatorFixtures {
    static let bootedUDID = "DCE5B544-A3A4-418D-AF1E-AC244F465CE3"
    static let shutdownUDID = "11111111-2222-3333-4444-555555555555"
    static let unavailableUDID = "99999999-8888-7777-6666-555555555555"

    /// A realistic two-runtime catalog: one booted iPhone, one shut down
    /// iPhone with the same name (older runtime), one unavailable iPad, and
    /// one record with a malformed UDID that must be skipped.
    static let listDevices = Data("""
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
          {
            "lastBootedAt" : "2026-07-10T07:34:14Z",
            "dataPath" : "/tmp/x",
            "dataPathSize" : 2125856768,
            "udid" : "\(bootedUDID)",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "state" : "Booted",
            "name" : "iPhone 17 Pro"
          },
          {
            "udid" : "not-a-udid",
            "isAvailable" : true,
            "state" : "Shutdown",
            "name" : "Corrupt Device"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
          {
            "udid" : "\(shutdownUDID)",
            "isAvailable" : true,
            "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            "state" : "Shutdown",
            "name" : "iPhone 17 Pro"
          },
          {
            "udid" : "\(unavailableUDID)",
            "isAvailable" : false,
            "availabilityError" : "runtime profile not found",
            "state" : "Shutdown",
            "name" : "iPad Pro 13-inch (M4)"
          }
        ]
      }
    }
    """.utf8)

    /// A single shut-down device, used by lifecycle tests.
    static func singleDevice(udid: String, state: String, available: Bool = true, name: String = "cmux-emu-test") -> Data {
        Data("""
        {
          "devices" : {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
              {
                "udid" : "\(udid)",
                "isAvailable" : \(available),
                "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "state" : "\(state)",
                "name" : "\(name)"
              }
            ]
          }
        }
        """.utf8)
    }
}
