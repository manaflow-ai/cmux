// swift-tools-version: 6.0

import PackageDescription

// Linux has no CryptoKit; swift-crypto provides the same API there.
var packageDependencies: [Package.Dependency] = []
var cryptoDependencies: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
cryptoDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

// The client side of the per-user text confirmation level
// (plans/cmux-next/home-messaging.md section 21): levels, the lowering flow
// with a presence-key proof over the owner's exact challenge bytes, and a
// mock owner. Platform neutral: the signer, App Attest and the ops are injected.
let package = Package(
    name: "CmuxTextConfirmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxTextConfirmCore", targets: ["CmuxTextConfirmCore"])],
    dependencies: packageDependencies,
    targets: [
        .target(name: "CmuxTextConfirmCore", dependencies: cryptoDependencies, swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxTextConfirmCoreTests", dependencies: ["CmuxTextConfirmCore"] + cryptoDependencies,
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
