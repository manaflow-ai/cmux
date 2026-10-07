// swift-tools-version: 6.0
import PackageDescription

// The phone half of the cmux.mobile/1 files family
// (plans/cmux-next/ios-next/c4-files.md): a client session over CmuxLink
// (hello with the device proof, odd channel ids, reads on one rpc channel),
// resumable sha256-verified upload and download, and the transfer journal
// and manager behind the iOS `FileTransfer` seam. Foundation and CryptoKit
// only, so its tests run on macOS against a real `MobileHost`.
let package = Package(
    name: "CmuxMobileFiles",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxMobileFiles", targets: ["CmuxMobileFiles"])],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxMobileWire"),
        .package(path: "../CmuxMobileHost"),
    ],
    targets: [
        .target(
            name: "CmuxMobileFiles",
            dependencies: [
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                // `MobileChannel` (the A0-on-link binding) and `DeviceProof` are shared with the Mac.
                .product(name: "CmuxMobileHost", package: "CmuxMobileHost"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileFilesTests",
            dependencies: [
                "CmuxMobileFiles",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxMobileHost", package: "CmuxMobileHost"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
