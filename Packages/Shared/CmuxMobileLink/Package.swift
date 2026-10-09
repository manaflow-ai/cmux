// swift-tools-version: 6.0
import PackageDescription

// cmux.mobile/1 bound onto CmuxLink, shared by both ends
// (plans/cmux-next/ios-next/b5-mac-host.md section 2, c1-terminal-rpc.md
// section 2): one A0 channel per LinkChannel, one StreamRecord per link
// message, the hello device proof, and the phone's session client
// (`MobileLinkClient`). No UIKit, no AppKit.
let package = Package(
    name: "CmuxMobileLink",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxMobileLink", targets: ["CmuxMobileLink"])],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxMobileWire"),
    ],
    targets: [
        .target(
            name: "CmuxMobileLink",
            dependencies: [
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileLinkTests",
            dependencies: [
                "CmuxMobileLink",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
