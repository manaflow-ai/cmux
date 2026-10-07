// swift-tools-version: 6.0
import PackageDescription

// The composition both ends of cmux.mobile/1 share
// (plans/cmux-next/ios-next/d1-terminal-ux.md section 2): the phone's
// `MobileLinkRegistry` (one `MobileLinkClient` per trusted Mac over a
// `PathSelector` of B4 direct, B2 WebRTC and, behind a DEV switch, B3
// WireGuard over WebRTC) and the Mac's `MobileHostAssembly` (the matching
// acceptors, B6 trust-store authorizers and B5's `MobileHost`). No UIKit, no
// AppKit, so the whole path is tested end to end on macOS.
let package = Package(
    name: "CmuxMobileConnect",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxMobileConnect", targets: ["CmuxMobileConnect"]),
        .library(name: "CmuxMobileConnectHost", targets: ["CmuxMobileConnectHost"]),
    ],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxLinkDirect"),
        .package(path: "../CmuxLinkWebRTC"),
        .package(path: "../CmuxLinkWG"),
        .package(path: "../CmuxMobileLink"),
        .package(path: "../CmuxMobileWire"),
        .package(path: "../CmuxMobileHost"),
        .package(path: "../CmuxPairing"),
        .package(path: "../CmuxTerminalLink"),
        .package(path: "../CmuxTerminalRenderCore"),
        .package(path: "../CmuxTerminalStream"),
    ],
    targets: [
        .target(
            name: "CmuxMobileConnect",
            dependencies: [
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkSignaling", package: "CmuxLink"),
                .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
                .product(name: "CmuxLinkWebRTC", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxLinkWebRTCUnderlay", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxLinkWG", package: "CmuxLinkWG"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxPairing", package: "CmuxPairing"),
            ]
        ),
        .target(
            name: "CmuxMobileConnectHost",
            dependencies: [
                "CmuxMobileConnect",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkSignaling", package: "CmuxLink"),
                .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
                .product(name: "CmuxLinkWebRTC", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxLinkWebRTCUnderlay", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxLinkWG", package: "CmuxLinkWG"),
                .product(name: "CmuxMobileHost", package: "CmuxMobileHost"),
                .product(name: "CmuxPairing", package: "CmuxPairing"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileConnectTests",
            dependencies: [
                "CmuxMobileConnect",
                "CmuxMobileConnectHost",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkSignaling", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxLinkDirect", package: "CmuxLinkDirect"),
                .product(name: "CmuxLinkWebRTC", package: "CmuxLinkWebRTC"),
                .product(name: "CmuxMobileHost", package: "CmuxMobileHost"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxPairing", package: "CmuxPairing"),
                .product(name: "CmuxTerminalLink", package: "CmuxTerminalLink"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
