// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAuthRuntime",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAuthRuntime",
            targets: ["CmuxAuthRuntime"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxEgress"),
        .package(path: "../CMUXAuthCore"),
        .package(path: "../../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "CmuxAuthRuntime",
            dependencies: [
                "CMUXAuthCore",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAuthRuntimeTests",
            dependencies: [
                "CmuxAuthRuntime",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

// The egress gate (docs/privacy.md, "Egress gate"): the targets that open connections make them through CmuxEgress.
for target in package.targets where ["CmuxAuthRuntime"].contains(target.name) {
    target.dependencies.append(.product(name: "CmuxEgress", package: "CmuxEgress"))
}
