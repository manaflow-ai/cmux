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
        // CmuxCore owns RemoteLoopbackProxyAlias, the single source of truth for
        // host normalization / loopback classification the insecure-HTTP allowlist
        // policy delegates to (leaf, acyclic).
        .package(path: "../CmuxCore"),
        // CmuxPanes owns PanelAppearance, whose shouldUseClearContentBackground
        // pure policy backs BrowserWebViewBackgroundDrawPolicy. Acyclic:
        // CmuxPanes deps never reach CmuxBrowser.
        .package(path: "../CmuxPanes"),
    ],
    targets: [
        .target(
            name: "CmuxBrowser",
            dependencies: [
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxAppKitSupportUI", package: "CmuxAppKitSupportUI"),
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
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
