// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileAuth",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileAuth",
            targets: ["CmuxMobileAuth"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXAuthCore"),
        .package(path: "../CMUXMobileCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "CmuxMobileAuth",
            dependencies: [
                "CMUXAuthCore",
                "CMUXMobileCore",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
