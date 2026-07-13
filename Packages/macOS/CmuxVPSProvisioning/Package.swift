// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxVPSProvisioning",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxVPSProvisioning",
            targets: ["CmuxVPSProvisioning"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxRemoteWorkspace"),
    ],
    targets: [
        .target(
            name: "CmuxVPSProvisioning",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxRemoteWorkspace", package: "CmuxRemoteWorkspace"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxVPSProvisioningTests",
            dependencies: [
                "CmuxVPSProvisioning",
                .product(name: "CmuxCore", package: "CmuxCore"),
            ]
        ),
    ]
)
