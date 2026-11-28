// swift-tools-version: 6.0

import PackageDescription

// The install principal client (identity spec D5): register this install's
// P-256 public key with a user session, prove the key with a one-time
// challenge, and hold the short-lived install token. Platform neutral (the
// signer and the HTTP transport are injected), so it tests on macOS.
let package = Package(
    name: "CmuxInstallAuthCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxInstallAuthCore", targets: ["CmuxInstallAuthCore"])],
    targets: [
        .target(name: "CmuxInstallAuthCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxInstallAuthCoreTests", dependencies: ["CmuxInstallAuthCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
