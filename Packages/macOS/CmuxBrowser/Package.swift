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
        // CmuxSettings owns BrowserSearchEngine, consumed by the suggestion service.
        .package(path: "../CmuxSettings"),
        // CmuxCore owns RemoteLoopbackProxyAlias, the host normalizer that
        // BrowserInsecureHTTPSettings forwards to.
        .package(path: "../CmuxCore"),
    ],
    targets: [
        .target(
            name: "CmuxBrowser",
            dependencies: [
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxCore", package: "CmuxCore"),
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
