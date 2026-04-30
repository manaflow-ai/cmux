// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXCLI",
    products: [
        .executable(
            name: "cmux",
            targets: ["cmux"]
        ),
    ],
    dependencies: [
        .package(name: "CMUXAuthCore", path: "../Packages/CMUXAuthCore"),
        .package(name: "CMUXCore", path: "../Packages/CMUXCore"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "cmux",
            dependencies: [
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CMUXCore", package: "CMUXCore"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: ".",
            sources: ["cmux.swift"]
        ),
    ]
)
