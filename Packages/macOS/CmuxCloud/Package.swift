// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxCloud",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CmuxCloud", targets: ["CmuxCloud"])],
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
        .package(path: "../CmuxSurfaceCatalogModel")
    ],
    targets: [
        .target(
            name: "CmuxCloud",
            dependencies: [
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
        )
    ]
)
