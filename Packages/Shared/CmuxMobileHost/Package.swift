// swift-tools-version: 6.0
import PackageDescription

// The Mac side of cmux.mobile/1 (plans/cmux-next/ios-next/b5-mac-host.md):
// `MobileHost` accepts CmuxLink sessions, authorizes paired devices, serves
// the rpc channel (workspace stream and ops) and bridges terminal channels to
// the cmux-tui session host through the `MobileDaemon` seam. It owns no
// entity: terminals and layout stay with the daemon.
let package = Package(
    name: "CmuxMobileHost",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxMobileHost", targets: ["CmuxMobileHost"])],
    dependencies: [
        .package(path: "../CmuxBrowserStream"),
        .package(path: "../CmuxControlPlane"),
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxMobileLink"),
        .package(path: "../CmuxMobileWire"),
        .package(path: "../CmuxRemoteDesktop"),
        .package(path: "../CmuxTerminalStream"),
    ],
    targets: [
        .target(
            name: "CmuxMobileHost",
            dependencies: [
                .product(name: "CmuxBrowserStream", package: "CmuxBrowserStream"),
                .product(name: "CmuxControlPlane", package: "CmuxControlPlane"),
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxRemoteDesktop", package: "CmuxRemoteDesktop"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileHostTests",
            dependencies: [
                "CmuxMobileHost",
                .product(name: "CmuxBrowserStream", package: "CmuxBrowserStream"),
                .product(name: "CmuxControlPlane", package: "CmuxControlPlane"),
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
                .product(name: "CmuxRemoteDesktop", package: "CmuxRemoteDesktop"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
