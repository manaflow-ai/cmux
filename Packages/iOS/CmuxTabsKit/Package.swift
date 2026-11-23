// swift-tools-version: 6.2

import PackageDescription

// CmuxTabsKit: a Mobile Safari style tab experience (tab grid, zoom
// transitions, pinch, floating glass toolbar) for any tab content.
// Integration guide: README.md. The UI is iOS 26+; the pure logic also
// builds on macOS so `swift test` runs on a Mac.
let package = Package(
    name: "CmuxTabsKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CmuxTabsKit", targets: ["CmuxTabsKit"]),
    ],
    dependencies: [.package(path: "../CmuxMobileSupport")],
    targets: [
        .target(name: "CmuxTabsKit", dependencies: [
            .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "CmuxTabsKitTests", dependencies: ["CmuxTabsKit"]),
    ],
    swiftLanguageModes: [.v6]
)
