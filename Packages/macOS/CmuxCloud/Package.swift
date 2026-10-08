// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxCloud",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxCloud", targets: ["CmuxCloud"]),
        .library(name: "CmuxCloudResizeCore", targets: ["CmuxCloudResizeCore"])
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXAuthCore"),
        .package(path: "../../Shared/CmuxAuthRuntime"),
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CmuxCloudBannerCore"),
        .package(path: "../CmuxCloudImagePaste"),
        .package(path: "../CmuxCloudMachines"),
        .package(path: "../CmuxCloudTui"),
        .package(path: "../CmuxCloudTunnelCore"),
        .package(path: "../CmuxControlSocket"),
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxMobileHost"),
        .package(path: "../CmuxPhonePush"),
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxSurfaceCatalogModel"),
        .package(path: "../CmuxTerminal")
    ],
    targets: [
        .target(
            name: "CmuxCloudResizeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CmuxCloud",
            dependencies: [
                "CmuxCloudResizeCore",
                "CMUXAuthCore",
                "CmuxAuthRuntime",
                "CMUXMobileCore",
                "CMUXDebugLog",
                "CmuxCloudBannerCore",
                "CmuxCloudImagePaste",
                "CmuxCloudMachines",
                "CmuxCloudTui",
                "CmuxCloudTunnelCore",
                "CmuxControlSocket",
                "CmuxCore",
                "CmuxFoundation",
                "CmuxMobileHost",
                "CmuxPhonePush",
                "CmuxSettings",
                "CmuxSurfaceCatalogModel"
            ],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CmuxCloudTests",
            dependencies: [
                "CmuxCloud",
                "CmuxAuthRuntime",
                "CmuxCloudTui",
                "CmuxCloudTunnelCore",
                "CMUXMobileCore",
                "CmuxPhonePush",
                "CmuxSurfaceCatalogModel",
                "CmuxCloudResizeCore",
                // CmuxTerminal binds libghostty, which SwiftPM cannot link here.
                .product(name: "CmuxTerminalGhosttyRuntimeTestStubs", package: "CmuxTerminal")
            ],
            // Most of these tests moved from the app's test target, which builds in Swift 5 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
