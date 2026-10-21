// swift-tools-version: 6.0

import PackageDescription

// Linux has no CryptoKit; swift-crypto provides the same API there.
var packageDependencies: [Package.Dependency] = []
var cryptoDependencies: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
cryptoDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

// The install principal client (identity spec D5): register this install's
// P-256 public key with a user session, prove the key with a one-time
// challenge, and hold the short-lived install token. Platform neutral (the
// signer and the HTTP transport are injected), so it tests on macOS.
let package = Package(
    name: "CmuxInstallAuthCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxInstallAuthCore", targets: ["CmuxInstallAuthCore"])],
    dependencies: packageDependencies,
    targets: [
        .target(name: "CmuxInstallAuthCore", dependencies: cryptoDependencies, swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxInstallAuthCoreTests", dependencies: ["CmuxInstallAuthCore"] + cryptoDependencies,
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
