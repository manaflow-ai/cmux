// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAPIClient",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAPIClient",
            targets: ["CmuxAPIClient"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.10.4"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "CmuxAPIClient",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
    ]
)
