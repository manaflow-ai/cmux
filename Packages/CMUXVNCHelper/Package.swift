// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXVNCHelper",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "cmux-vnc-helper",
            targets: ["CMUXVNCHelper"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXVNC"),
        .package(
            url: "https://github.com/royalapplications/royalvnc.git",
            revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea"
        ),
    ],
    targets: [
        .executableTarget(
            name: "CMUXVNCHelper",
            dependencies: [
                .product(name: "CMUXVNC", package: "CMUXVNC"),
                .product(name: "RoyalVNCKit", package: "royalvnc"),
            ]
        ),
    ]
)
