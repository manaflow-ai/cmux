// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowser",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowser",
            targets: ["CmuxBrowser"]
        ),
    ],
    dependencies: [
        .package(path: "../../../vendor/bonsplit"),
        // CMUXDebugLog backs the ReactGrab/ toggle DEBUG logging (#if DEBUG only).
        .package(path: "../CMUXDebugLog"),
        // CmuxSettings owns BrowserSearchEngine, the omnibar suggestion domain type.
        .package(path: "../CmuxSettings"),
        // CmuxAppKitSupportUI owns WindowChromeColorResolver, the chrome color math
        // BrowserChromeStyle routes compositing/readable-scheme selection through.
        .package(path: "../CmuxAppKitSupportUI"),
    ],
    targets: [
        .target(
            name: "CmuxBrowser",
            dependencies: [
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserTests",
            dependencies: ["CmuxBrowser"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
