// swift-tools-version: 6.0

import PackageDescription

// App Attest and DeviceCheck for the cmux apps (cx-ds09i): the platform half
// of a device proof. The protocol seams let the Mac free-tier provider and
// the iOS presence-key flow take the real service or a stand-in; the
// product logic that uses a proof lives elsewhere (the relay, the server).
let package = Package(
    name: "CmuxAppAttest",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxAppAttest", targets: ["CmuxAppAttest"])],
    targets: [
        .target(name: "CmuxAppAttest", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
