// swift-tools-version: 6.0
import PackageDescription

// The phone's side of the cmux session host terminal
// (plans/cmux-next/ios-next/c1-terminal-rpc.md): `LinkTerminalByteSource`
// implements A2's `TerminalByteSource` (`.host` authority) over a
// `cmux.mobile/1` terminal channel, with the delivery drop queue, echo
// prediction and latency telemetry. No UIKit, so it is tested end to end on
// macOS against a real `MobileHost`.
let package = Package(
    name: "CmuxTerminalLink",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxTerminalLink", targets: ["CmuxTerminalLink"])],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxMobileLink"),
        .package(path: "../CmuxMobileWire"),
        .package(path: "../CmuxTerminalStream"),
        .package(path: "../CmuxTerminalRenderCore"),
        .package(path: "../CmuxMobileHost"),
        .package(path: "../CmuxTerminalSizing"),
    ],
    targets: [
        .target(
            name: "CmuxTerminalLink",
            dependencies: [
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalLinkTests",
            dependencies: [
                "CmuxTerminalLink",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
                .product(name: "CmuxTerminalRenderCore", package: "CmuxTerminalRenderCore"),
                .product(name: "CmuxMobileHost", package: "CmuxMobileHost"),
                .product(name: "CmuxTerminalSizing", package: "CmuxTerminalSizing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
