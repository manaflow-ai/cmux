// swift-tools-version: 6.2

import PackageDescription

// CmuxDeviceHub: a cmux app's side of the device hub (docs/device-hub/PROTOCOL.md):
// this device's identity (Secure Enclave keys; software keys in the iOS
// simulator, which has no enclave), the device-signed HTTP client, the User DO
// socket, relay secret sealing and the `DeviceHub` model a UI reads. No UI.
//
// The iOS app's Screen Sharing viewer uses it. It began as a copy of the macOS
// app's CmuxNextDevices target (Packages/macOS/CmuxNext), which keeps its own
// copy until it moves onto this package.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxDeviceHub",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CmuxDeviceHub", targets: ["CmuxDeviceHub"]),
    ],
    targets: [
        .target(name: "CmuxDeviceHub", swiftSettings: swiftSettings),
        .testTarget(name: "CmuxDeviceHubTests", dependencies: ["CmuxDeviceHub"], swiftSettings: swiftSettings),
    ]
)
