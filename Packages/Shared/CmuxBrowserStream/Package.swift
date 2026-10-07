// swift-tools-version: 6.0
import PackageDescription

// Browser surface streaming between the Mac and the phone
// (plans/cmux-next/ios-next/c2-browser-stream.md): the cmux.rd/1 and
// cmux.rb/1 wire in Swift (datagram header, frame bodies, feedback, input
// packets, rb messages), the packetizer and reassembler, H.264 Annex-B
// helpers, and the phone-side client of one `browser` channel over CmuxLink.
// No UIKit, no AppKit: the Mac handler (CmuxMobileHost) and the iOS screen
// (CmuxiOSBrowser) both build on it.
let package = Package(
    name: "CmuxBrowserStream",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxBrowserStream", targets: ["CmuxBrowserStream"])],
    dependencies: [
        .package(path: "../CmuxLink"),
        .package(path: "../CmuxMobileWire"),
    ],
    targets: [
        .target(
            name: "CmuxBrowserStream",
            dependencies: [
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserStreamTests",
            dependencies: [
                "CmuxBrowserStream",
                .product(name: "CmuxLink", package: "CmuxLink"),
                .product(name: "CmuxLinkTesting", package: "CmuxLink"),
                .product(name: "CmuxMobileWire", package: "CmuxMobileWire"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
