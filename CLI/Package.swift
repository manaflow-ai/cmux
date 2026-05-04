// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(name: "CMUXAuthCore", path: "../Packages/CMUXAuthCore"),
]

let cmuxTargetDependencies: [Target.Dependency] = [
    .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
]

let cmuxSources = ["LinuxAuthBridgeMain.swift"]
#else
let packageDependencies: [Package.Dependency] = [
    .package(name: "CMUXAuthCore", path: "../Packages/CMUXAuthCore"),
    .package(name: "CMUXCore", path: "../Packages/CMUXCore"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]

let cmuxTargetDependencies: [Target.Dependency] = [
    .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
    .product(name: "CMUXCore", package: "CMUXCore"),
    .product(name: "Crypto", package: "swift-crypto"),
]

let cmuxSources = ["cmux.swift"]
#endif

let package = Package(
    name: "CMUXCLI",
    products: [
        .executable(
            name: "cmux",
            targets: ["cmux"]
        ),
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "cmux",
            dependencies: cmuxTargetDependencies,
            path: ".",
            sources: cmuxSources
        ),
    ]
)
