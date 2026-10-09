// swift-tools-version: 6.0
import PackageDescription

// Remote desktop between the Mac and the phone
// (plans/cmux-next/ios-next/c3-rd.md): the `rd` channel params, the
// `desktop/1` control vocabulary, view geometry shared by both ends, HID
// key tables, and the phone-side client of one `rd` channel. The rd wire
// itself (datagram header, frame bodies, input packets, reassembly) comes
// from CmuxBrowserStream. No UIKit, no AppKit.
let package = Package(
    name: "CmuxRemoteDesktop",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxRemoteDesktop", targets: ["CmuxRemoteDesktop"])],
    dependencies: [
        .package(path: "../CmuxBrowserStream"),
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxMobileLink"),
        .package(path: "../CmuxMobileWire"),
    ],
    targets: [
        .target(
            name: "CmuxRemoteDesktop",
            dependencies: [
                .product(name: "CmuxBrowserStream", package: "CmuxBrowserStream"),
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
        .testTarget(
            name: "CmuxRemoteDesktopTests",
            dependencies: [
                "CmuxRemoteDesktop",
                .product(name: "CmuxBrowserStream", package: "CmuxBrowserStream"),
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileLink", package: "CmuxMobileLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
