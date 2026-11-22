// swift-tools-version: 6.0

import PackageDescription

// The client side of the per-user text confirmation level
// (plans/cmux-next/home-messaging.md section 21): levels, the lowering flow
// with a presence-key proof over the owner's exact challenge bytes, and a
// mock owner. Platform neutral: the signer, App Attest and the ops are injected.
let package = Package(
    name: "CmuxTextConfirmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxTextConfirmCore", targets: ["CmuxTextConfirmCore"])],
    targets: [
        .target(name: "CmuxTextConfirmCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxTextConfirmCoreTests", dependencies: ["CmuxTextConfirmCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
